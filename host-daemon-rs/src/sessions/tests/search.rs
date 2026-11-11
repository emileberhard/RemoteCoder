use super::*;

fn conversation_search(
    store: &Store,
    query: &str,
    limit: usize,
    parents: std::collections::HashMap<String, Option<String>>,
) -> crate::sessions::conversations::Response {
    {
        let db = store.writer().unwrap();
        for (key, parent) in parents {
            db.execute("UPDATE session SET delegated_parent_known=1,delegated_parent_session_key=?2 WHERE session_key=?1",rusqlite::params![key,parent]).unwrap();
        }
    }
    {
        let mut db = store.writer().unwrap();
        while crate::sessions::index::rebuild_one(&mut db).unwrap() {}
    }
    let control = crate::sessions::store::ReadControl::new(
        Instant::now() + crate::sessions::conversations::DEADLINE,
    );
    let mut db = store.reader().unwrap();
    db.interrupt_on(control.clone()).unwrap();
    crate::sessions::conversations::search(
        &db,
        &crate::sessions::conversations::Request {
            query: query.into(),
            limit,
        },
        &control,
        &Default::default(),
    )
    .unwrap()
}

fn conversation_item(
    db: &rusqlite::Connection,
    key: &str,
    id: usize,
    text: &str,
    kind: &str,
    at: Option<&str>,
) {
    db.execute("INSERT INTO item(item_key,session_key,seq,at,kind,text,text_bytes,source_ref,revision) VALUES(?1,?2,?3,?4,?5,?6,?7,'{}',1)", rusqlite::params![format!("fixture-item-{id}"), key, id as i64, at, kind, text, text.len() as i64]).unwrap();
}

#[test]
fn sessions_conversation_hit_destination_matches_catalog_locate() -> Result<()> {
    let f = fixture();
    write(
        &f.codex.with_file_name("child.jsonl"),
        &[
            codex_meta("codex-child", None),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"DelegatedChildNeedle"}}),
        ],
    );
    scan(&f);
    let codex_root = crate::sessions::session_key(&f.origins[0], "codex-root");
    let codex_child = crate::sessions::session_key(&f.origins[0], "codex-child");
    let claude_root = crate::sessions::session_key(&f.origins[1], "claude_root");
    let parents = [(codex_child, Some(codex_root.clone()))]
        .into_iter()
        .collect();
    let codex = conversation_search(&f.store, "DelegatedChildNeedle", 1, parents);
    let claude = conversation_search(&f.store, "Native child", 1, Default::default());
    let folded_claude = conversation_search(
        &f.store,
        "Native child",
        1,
        [(claude_root, Some(codex_root))].into_iter().collect(),
    );
    for (result, expected, claude_agent) in [
        (codex, Some("codex-child"), None),
        (claude, None, Some("child")),
        (folded_claude, Some("claude_root"), Some("child")),
    ] {
        let conversation = &result.conversations[0];
        let hit = conversation.hit.as_ref().unwrap();
        let control = crate::sessions::store::ReadControl::new(
            Instant::now() + crate::sessions::conversations::DEADLINE,
        );
        let located = crate::sessions::locate::item(
            &f.store.reader()?,
            &crate::sessions::locate::Request {
                item_key: hit.item_key.clone(),
            },
            &control,
        )?;
        assert_eq!(hit.agent_thread_id.as_deref(), expected);
        assert_eq!(located.claude_agent_id.as_deref(), claude_agent);
        assert_eq!(
            hit.agent_thread_id
                .as_deref()
                .unwrap_or(&conversation.thread_id),
            located.response.thread_id,
        );
    }
    Ok(())
}

#[test]
fn sessions_conversations_match_across_messages_fold_and_rank_titles() {
    let f = fixture();
    let outcome = scan(&f);
    let failures: Vec<(String, Option<String>)> = f
        .store
        .reader()
        .unwrap()
        .prepare("SELECT path,failure FROM source")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert_eq!(outcome["parseFailures"], 0, "{failures:?}");
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    let child = crate::sessions::session_key(&f.origins[0], "codex-child");
    let other = crate::sessions::session_key(&f.origins[1], "claude_root");
    {
        let db = f.store.writer().unwrap();
        db.execute("DELETE FROM item", []).unwrap();
        db.execute("UPDATE session SET title=NULL,cwd=NULL", [])
            .unwrap();
        conversation_item(&db, &root, 0, "drawer", "user", None);
        conversation_item(&db, &child, 1, "flickering Malmö ui", "assistant", None);
        conversation_item(&db, &other, 2, "drawer unrelated", "assistant", None);
    }
    let result = conversation_search(&f.store, "drawer flick", 30, Default::default());
    assert_eq!(result.conversations.len(), 1);
    assert_eq!(result.conversations[0].session_key, root);
    assert_eq!(result.conversations[0].hit_count, 2);
    assert!(
        result.conversations[0]
            .hit
            .iter()
            .any(|h| h.agent_thread_id.as_deref() == Some("codex-child"))
    );
    for term in ["malmo", "ui"] {
        assert_eq!(
            conversation_search(&f.store, term, 30, Default::default()).conversations[0]
                .session_key,
            root
        );
    }
    {
        let db = f.store.writer().unwrap();
        db.execute(
            "UPDATE session SET title='Drawer flickering' WHERE session_key=?1",
            [&other],
        )
        .unwrap();
    }
    let result = conversation_search(&f.store, "drawer flick", 1, Default::default());
    assert_eq!(result.conversations.len(), 1);
    assert_eq!(result.conversations[0].session_key, other);
    assert!(result.conversations[0].title_match);
    let promoted = conversation_search(&f.store, "flick", 30, [(child.clone(), None)].into());
    assert!(
        promoted
            .conversations
            .iter()
            .any(|c| c.session_key == child && c.hit.iter().all(|h| h.agent_thread_id.is_none()))
    );
}

#[test]
fn sessions_conversations_refold_all_descendants_when_ancestor_arrives() -> Result<()> {
    for b_first in [false, true] {
        let f = fixture();
        let origin = &f.origins[0];
        let a = f.codex.with_file_name("a.jsonl");
        let b = f.codex.with_file_name("b.jsonl");
        let c = f.codex.with_file_name("c.jsonl");
        let key = |id| crate::sessions::session_key(origin, id);
        let stop = AtomicBool::new(false);
        let mut b_header = codex_meta("b", Some("a"));
        if b_first {
            b_header["timestamp"] = json!("2026-10-29T10:00:00Z");
        }
        write(
            &b,
            &[
                b_header,
                json!({"type":"event_msg","payload":{"type":"user_message","message":"ancestry chain middle"}}),
            ],
        );
        write(
            &c,
            &[
                codex_meta("c", Some("b")),
                json!({"type":"event_msg","payload":{"type":"user_message","message":"ancestry chain leaf"}}),
            ],
        );
        ingest::scan_scope(
            &f.store,
            &f.origins,
            ingest::Scope::Changed(&[b.clone(), c]),
            &stop,
        )?;
        let grouped = conversation_search(&f.store, "ancestry", 30, Default::default());
        assert_eq!(grouped.conversations.len(), 1);
        assert_eq!(grouped.conversations[0].session_key, key("b"));
        assert_eq!(grouped.conversations[0].hit_count, 2);
        f.store.writer()?.execute(
            "INSERT INTO search_dirty(session_key,relink) VALUES(?1,1)",
            [key("b")],
        )?;
        let mut a_header = codex_meta("a", None);
        a_header["timestamp"] = json!("2026-10-28T10:00:00Z");
        write(&a, &[a_header]);
        ingest::scan_scope(&f.store, &f.origins, ingest::Scope::Changed(&[a]), &stop)?;
        let db = f.store.reader()?;
        let documents: Vec<String> = db
            .prepare("SELECT session_key FROM search_document WHERE session_key IN (?1,?2,?3)")?
            .query_map(rusqlite::params![key("a"), key("b"), key("c")], |r| {
                r.get(0)
            })?
            .collect::<rusqlite::Result<_>>()?;
        assert_eq!(documents, [key("a")]);
        let grouped = conversation_search(&f.store, "ancestry", 30, Default::default());
        assert_eq!(grouped.conversations.len(), 1);
        assert_eq!(grouped.conversations[0].session_key, key("a"));
        assert_eq!(grouped.conversations[0].hit_count, 2);
    }
    Ok(())
}

#[test]
fn sessions_conversations_share_document_and_hit_kinds() -> Result<()> {
    let f = fixture();
    scan(&f);
    let key = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer()?;
        conversation_item(&db, &key, 900, "reasoningfixture", "reasoning", None);
        conversation_item(
            &db,
            &key,
            901,
            "reasoningfixture toolonlyfixture",
            "tool_result",
            None,
        );
        conversation_item(
            &db,
            &key,
            902,
            "reasoningfixture systemonlyfixture",
            "system",
            None,
        );
    }
    let result = conversation_search(&f.store, "reasoningfixture", 30, Default::default());
    assert!(result.conversations.is_empty());
    assert!(
        conversation_search(&f.store, "toolonlyfixture", 30, Default::default())
            .conversations
            .is_empty()
    );
    assert_eq!(
        search(&f.store, "toolonlyfixture")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    {
        let db = f.store.writer()?;
        db.execute(
            "UPDATE item SET kind='assistant' WHERE item_key='fixture-item-901'",
            [],
        )?;
        db.execute(
            "UPDATE item SET kind='tool_result' WHERE item_key='fixture-item-900'",
            [],
        )?;
    }
    let result = conversation_search(&f.store, "reasoningfixture", 30, Default::default());
    assert_eq!(result.conversations[0].hit_count, 1);
    let kind: String = f.store.reader()?.query_row(
        "SELECT kind FROM item WHERE item_key=?1",
        [&result.conversations[0].hit.as_ref().unwrap().item_key],
        |r| r.get(0),
    )?;
    assert_eq!(kind, "assistant");
    Ok(())
}

#[test]
fn sessions_conversations_bound_hits_and_exclude_folder_only_matches() {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer().unwrap();
        db.execute("DELETE FROM item", []).unwrap();
        db.execute("UPDATE session SET title=NULL,cwd='/needle'", [])
            .unwrap();
        for id in 0..=crate::sessions::conversations::TERM_WINDOW {
            conversation_item(&db, &root, id, "needle", "assistant", None);
        }
    }
    let result = conversation_search(&f.store, "needle", 30, Default::default());
    assert!(!result.truncated);
    assert_eq!(result.conversations.len(), 1);
    assert_eq!(
        result.conversations[0].hit_count,
        crate::sessions::conversations::TERM_WINDOW
    );
    assert!(result.conversations[0].hit.is_some());
    assert!(
        conversation_search(&f.store, "absent needle", 30, Default::default())
            .conversations
            .is_empty()
    );
}

#[test]
fn sessions_conversations_truncation_reports_backfill_instead_of_result_windows() -> Result<()> {
    let f = fixture();
    for number in 0..130 {
        write(
            &f.claude.with_file_name(format!("window-{number}.jsonl")),
            &[json!({"type":"user","uuid":format!("prompt-{number}"),
                "message":{"role":"user","content":format!("CommonWindowNeedle {}",if number==0 {"RareWindowNeedle"} else {""})}})],
        );
    }
    scan(&f);
    f.store.writer()?.execute(
        "UPDATE coverage SET stale_reason='incomplete_evidence',complete_through=NULL",
        [],
    )?;
    for query in ["CommonWindowNeedle", "RareWindowNeedle"] {
        let result = conversation_search(&f.store, query, 30, Default::default());
        assert!(!result.truncated);
        assert!(!result.conversations.is_empty());
    }
    f.store
        .writer()?
        .execute("UPDATE meta SET value='old' WHERE key='search_version'", [])?;
    crate::sessions::index::open(&*f.store.writer()?)?;
    for query in ["CommonWindowNeedle", "RareWindowNeedle"] {
        let control = crate::sessions::store::ReadControl::new(
            Instant::now() + crate::sessions::conversations::DEADLINE,
        );
        let result = crate::sessions::conversations::search(
            &f.store.reader()?,
            &crate::sessions::conversations::Request {
                query: query.into(),
                limit: 30,
            },
            &control,
            &Default::default(),
        )?;
        assert!(result.truncated);
    }
    Ok(())
}

#[test]
fn sessions_conversations_rebuild_indexes_from_rows_and_report_pending_work() {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer().unwrap();
        conversation_item(&db, &root, 999, "PreciseIdentifier", "assistant", None);
    }
    let request = crate::sessions::conversations::Request {
        query: "PreciseIdentifier".into(),
        limit: 30,
    };
    let control = crate::sessions::store::ReadControl::new(
        Instant::now() + crate::sessions::conversations::DEADLINE,
    );
    assert_eq!(
        conversation_search(&f.store, "PreciseIdentifier", 30, Default::default()).conversations[0]
            .session_key,
        root
    );
    {
        let db = f.store.writer().unwrap();
        db.execute("UPDATE meta SET value='old' WHERE key='search_version'", [])
            .unwrap();
        crate::sessions::index::open(&db).unwrap();
    }
    assert!(
        crate::sessions::conversations::search(
            &f.store.reader().unwrap(),
            &request,
            &control,
            &Default::default()
        )
        .unwrap()
        .truncated
    );
    assert_eq!(
        conversation_search(&f.store, "PreciseIdentifier", 30, Default::default()).conversations[0]
            .session_key,
        root
    );
}

#[test]
fn sessions_conversations_store_open_leaves_derived_upgrades_to_worker() -> Result<()> {
    let f = fixture();
    scan(&f);
    f.store.writer()?.execute_batch(
        "UPDATE meta SET value='old' WHERE key='search_version'; DROP TABLE search_document;",
    )?;
    let reopened = Store::open(
        f.store.path.clone(),
        crate::sessions::storage::Capacity::Fixed {
            free_bytes: 1 << 40,
        },
    )?;
    let db = reopened.reader()?;
    let version: String = db.query_row(
        "SELECT value FROM meta WHERE key='search_version'",
        [],
        |r| r.get(0),
    )?;
    assert_eq!(version, "old");
    let request = crate::sessions::conversations::Request {
        query: "fixture".into(),
        limit: 30,
    };
    let control = crate::sessions::store::ReadControl::new(
        Instant::now() + crate::sessions::conversations::DEADLINE,
    );
    let response =
        crate::sessions::conversations::search(&db, &request, &control, &Default::default())?;
    assert!(response.truncated);
    assert!(response.conversations.is_empty());
    assert!(
        query::sql(&db, "SELECT 1")?["coverage"]["conversationSearch"]["cappedRoots"].is_null()
    );
    Ok(())
}

#[test]
fn sessions_conversations_defer_expensive_refreshes_without_marking_partial() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    let mut db = f.store.writer()?;
    db.execute(
        "UPDATE coverage SET stale_reason=NULL,complete_through='2026-11-01'",
        [],
    )?;
    db.execute("UPDATE meta SET value='1' WHERE key='catalog_ready'", [])?;
    db.execute("UPDATE search_document SET refreshed_ms=CAST(unixepoch('subsec')*1000 AS INTEGER),cooldown_ms=60000 WHERE session_key=?1", [&root])?;
    conversation_item(&db, &root, 1000, "DeferredIdentifier", "assistant", None);
    let stopped = AtomicBool::new(false);
    let next = crate::sessions::index::drain(&mut db, &stopped, &mut |_| Ok(()))?;
    assert!(next.is_some_and(|next| next > Instant::now()));
    let query = |term: &str| {
        let request = crate::sessions::conversations::Request {
            query: term.into(),
            limit: 30,
        };
        let control = crate::sessions::store::ReadControl::new(
            Instant::now() + crate::sessions::conversations::DEADLINE,
        );
        crate::sessions::conversations::search(
            &f.store.reader()?,
            &request,
            &control,
            &Default::default(),
        )
    };
    let pending = query("DeferredIdentifier")?;
    assert!(!pending.truncated);
    assert!(pending.conversations.is_empty());
    db.execute(
        "UPDATE search_document SET refreshed_ms=0 WHERE session_key=?1",
        [&root],
    )?;
    assert!(crate::sessions::index::drain(&mut db, &stopped, &mut |_| Ok(()))?.is_none());
    assert_eq!(
        query("DeferredIdentifier")?.conversations[0].session_key,
        root
    );
    Ok(())
}

#[test]
fn sessions_conversations_cap_both_document_text_columns() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer()?;
        let cap = crate::sessions::index::DOCUMENT_COLUMN_BYTES as usize;
        for (offset, kind) in [(1000, "assistant"), (1002, "user")] {
            conversation_item(
                &db,
                &root,
                offset,
                &format!("Old{kind}Anchor {}", "old ".repeat(40)),
                kind,
                None,
            );
            let newest = format!("Newest{kind}Anchor ");
            conversation_item(
                &db,
                &root,
                offset + 1,
                &format!("{newest}{}", "cd ".repeat((cap - newest.len() - 16) / 3)),
                kind,
                None,
            );
        }
    }
    let search = |query: &str| conversation_search(&f.store, query, 1, Default::default());
    for kind in ["assistant", "user"] {
        assert!(search(&format!("Old{kind}Anchor")).conversations.is_empty());
        assert_eq!(
            search(&format!("Newest{kind}Anchor")).conversations[0].session_key,
            root
        );
    }
    let db = f.store.reader()?;
    let status = crate::sessions::query::sql(&db, "SELECT 1")?;
    assert_eq!(status["coverage"]["conversationSearch"]["cappedRoots"], 1);
    Ok(())
}

#[test]
fn sessions_conversations_index_pasted_payload_and_skip_injected_prompt_text() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    let prompt = format!(
        "CaptionAnchor\n\n<remotecoder_pasted_text_v1>\n{}\n</remotecoder_pasted_text_v1>\n\n{}- /AttachedPathAnchor\n<remotecoder_note>\nInjectedNoteAnchor\n</remotecoder_note>",
        json!([{"id":"11111111-2222-4333-8444-555555555555","text":"PastedPayloadAnchor"}]),
        crate::prompt_summary::ATTACHED_FILES_HEADER,
    );
    conversation_item(&*f.store.writer()?, &root, 1000, &prompt, "user", None);
    let found = conversation_search(
        &f.store,
        "CaptionAnchor PastedPayloadAnchor",
        1,
        Default::default(),
    );
    assert_eq!(found.conversations[0].session_key, root);
    assert!(
        found.conversations[0]
            .hit
            .as_ref()
            .unwrap()
            .excerpt
            .contains("PastedPayloadAnchor")
    );
    for ignored in ["InjectedNoteAnchor", "AttachedPathAnchor"] {
        assert!(
            conversation_search(&f.store, ignored, 1, Default::default())
                .conversations
                .is_empty()
        );
    }
    assert_eq!(
        crate::prompt_summary::prompt_summary(&prompt),
        "CaptionAnchor"
    );
    Ok(())
}

#[test]
fn sessions_conversations_ignore_punctuation_only_query_terms() -> Result<()> {
    let f = fixture();
    scan(&f);
    let key = crate::sessions::session_key(&f.origins[0], "codex-root");
    f.store.writer()?.execute(
        "UPDATE session SET title='Fix arrow a b' WHERE session_key=?1",
        [&key],
    )?;
    for query in ["fix -> arrow", "fix — arrow", "a & b"] {
        let result = conversation_search(&f.store, query, 30, Default::default());
        assert_eq!(result.conversations.len(), 1);
        assert!(result.conversations[0].title_match);
    }
    assert!(
        crate::sessions::conversations::Request {
            query: "\"".into(),
            limit: 30
        }
        .terms()
        .is_err()
    );
    Ok(())
}

#[test]
fn sessions_conversations_validate_the_pinned_params() {
    use crate::sessions::conversations::Request;
    for value in [
        json!({"query":"ok"}),
        json!({"query":"ok","limit":1,"local":true}),
        json!({"query":"ok","limit":-1}),
    ] {
        assert!(serde_json::from_value::<Request>(value).is_err());
    }
    for (query, limit) in [
        (" ".into(), 1),
        ("a".into(), 0),
        ("a".into(), 51),
        ("å".repeat(257), 1),
        ("a b c d e f g h i".into(), 1),
    ] {
        assert!(Request { query, limit }.terms().is_err());
    }
    assert_eq!(
        Request {
            query: "  ÅÄ åä UI ui  ".into(),
            limit: 50
        }
        .terms()
        .unwrap(),
        ["åä", "ui"]
    );
    assert!(
        Request {
            query: "å".repeat(256),
            limit: 1
        }
        .terms()
        .is_ok()
    );
}

#[tokio::test]
async fn sessions_conversations_cancellation_interrupts_sql_and_releases_reader_permit() {
    let f = fixture();
    let pool = Arc::new(tokio::sync::Semaphore::new(1));
    let permit = pool.clone().acquire_owned().await.unwrap();
    let control = crate::sessions::store::ReadControl::new(
        Instant::now() + std::time::Duration::from_secs(5),
    );
    let guard = control.cancel_on_drop();
    let store = f.store.clone();
    let (started, running) = tokio::sync::oneshot::channel();
    let (finished, result) = tokio::sync::oneshot::channel();
    let request = tokio::spawn(async move {
        let _guard = guard;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let mut db = store.reader().unwrap();
            db.interrupt_on(control).unwrap();
            started.send(()).unwrap();
            let output = db.query_row("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n", [], |r| r.get::<_, i64>(0));
            let _ = finished.send(output);
        }).await.unwrap();
    });
    running.await.unwrap();
    request.abort();
    assert!(request.await.unwrap_err().is_cancelled());
    let acquired = tokio::time::timeout(std::time::Duration::from_secs(1), pool.acquire())
        .await
        .unwrap()
        .unwrap();
    drop(acquired);
    let error = result.await.unwrap().unwrap_err();
    assert!(
        matches!(error, rusqlite::Error::SqliteFailure(code, _) if code.code == rusqlite::ErrorCode::OperationInterrupted)
    );
}

#[test]
fn sessions_conversations_ingest_typed_prompts_and_steers_only() -> Result<()> {
    let f = fixture();
    let mut file = OpenOptions::new().append(true).open(&f.codex)?;
    for record in [
        json!({"type":"event_msg","payload":{"type":"user_message","message":"typed steering sentinel"}}),
        json!({"type":"event_msg","payload":{"type":"user_message","message":"<agent_message id=\"x\">injected agent</agent_message>"}}),
        json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}),
    ] {
        writeln!(file, "{record}")?;
    }
    let mut file = OpenOptions::new().append(true).open(&f.claude)?;
    for record in [
        json!({"type":"user","uuid":"compaction","isCompactSummary":true,"message":{"content":"compaction summary sentinel"}}),
        json!({"type":"attachment","attachment":{"type":"queued_command","commandMode":"prompt","source_uuid":"queued","prompt":"queued steering sentinel"}}),
        json!({"type":"user","uuid":"agent","message":{"content":"<agent_message id=\"x\">injected agent</agent_message>"}}),
    ] {
        writeln!(file, "{record}")?;
    }
    assert_eq!(scan(&f)["parseFailures"], 0);
    let texts: Vec<String> = f
        .store
        .reader()?
        .prepare("SELECT text FROM item WHERE kind='user' AND text<>'' ORDER BY text")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    assert_eq!(
        texts,
        [
            "Inspect fixture",
            "Native child",
            "queued steering sentinel",
            "typed steering sentinel"
        ]
    );
    Ok(())
}

#[tokio::test]
async fn sessions_conversations_mirror_origin_metadata_without_entry_changes() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    let child = crate::sessions::session_key(&f.origins[0], "codex-child");
    let directory = tempfile::tempdir()?;
    let target = fixture_store(directory.path().join("state/catalog.sqlite3"))?;
    let worker = start_worker(&target, &[]);
    let call = mirror_peer(&f, Default::default(), Default::default());
    sync_mirror(&target, call.clone()).await?;
    f.store.writer()?.execute("UPDATE session SET title='Native Codex title',delegated_parent_known=1,delegated_parent_session_key=?2 WHERE session_key=?1",rusqlite::params![child,root])?;
    let page = mirror::list(&f.store, "fixture", None)?;
    let _: Vec<mirror::Entry> = serde_json::from_value(page["files"].clone())?;
    sync_mirror(&target, call).await?;
    let metadata:(String,bool,String)=target.reader()?.query_row("SELECT title,delegated_parent_known,delegated_parent_session_key FROM session WHERE session_key=?1",[child],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
    assert_eq!(metadata, ("Native Codex title".into(), true, root));
    worker.stop()?;
    Ok(())
}

#[test]
fn sessions_conversations_select_codex_user_evidence_by_source_shape() -> Result<()> {
    let completed = |id: &str, text: &str| json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"UserMessage","id":id,"content":[{"type":"text","text":text},{"type":"image","image_url":"data:image/png;base64,aGVsbG8="}]}}});
    let old_event = json!({"type":"event_msg","payload":{"type":"user_message","message":"AuthoritativeTypedAnchor"}});
    let response = json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ResponseTypedAnchor"}]}});
    for (shape, events, expected) in [
        ("response-only", vec![], vec!["ResponseTypedAnchor"]),
        (
            "legacy-event",
            vec![old_event.clone()],
            vec!["AuthoritativeTypedAnchor"],
        ),
        (
            "paginated",
            vec![
                completed("native-first", "AuthoritativeTypedAnchor"),
                completed("native-steer", "SteerTypedAnchor"),
            ],
            vec!["AuthoritativeTypedAnchor", "SteerTypedAnchor"],
        ),
        (
            "switched",
            vec![
                old_event,
                response.clone(),
                completed("native-steer", "SteerTypedAnchor"),
            ],
            vec!["AuthoritativeTypedAnchor", "SteerTypedAnchor"],
        ),
    ] {
        let f = fixture();
        let mut records = vec![
            codex_meta("codex-root", None),
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}),
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n<INSTRUCTIONS>context</INSTRUCTIONS>"},{"type":"input_text","text":"<environment_context>context</environment_context>"}]}}),
            response.clone(),
        ];
        records.extend(events);
        write(&f.codex, &records);
        scan(&f);
        let key = crate::sessions::session_key(&f.origins[0], "codex-root");
        let users: Vec<String> = f
            .store
            .reader()?
            .prepare("SELECT text FROM item WHERE session_key=?1 AND kind='user' ORDER BY seq")?
            .query_map([&key], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        assert_eq!(users, expected, "{shape}");
        for query in expected {
            assert_eq!(
                conversation_search(&f.store, query, 1, Default::default()).conversations[0]
                    .session_key,
                key,
                "{shape}"
            );
        }
        if shape == "paginated" {
            let item: String = f.store.reader()?.query_row("SELECT item_key FROM item WHERE session_key=?1 AND kind='user' ORDER BY seq LIMIT 1",[&key],|r|r.get(0))?;
            let control = crate::sessions::store::ReadControl::new(
                Instant::now() + crate::sessions::conversations::DEADLINE,
            );
            let located = crate::sessions::locate::item(
                &*f.store.reader()?,
                &crate::sessions::locate::Request { item_key: item },
                &control,
            )?;
            assert_eq!(located.provider_item_id.as_deref(), Some("native-first"));
        }
    }
    Ok(())
}

#[test]
fn sessions_conversations_preserve_origin_facts_through_replacement() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = crate::sessions::session_key(&f.origins[0], "codex-root");
    let child = crate::sessions::session_key(&f.origins[0], "codex-child");
    let titles = f.origins[0].local_home.join("session_index.jsonl");
    write(
        &titles,
        &[
            json!({"id":"codex-root","thread_name":"Native root title"}),
            json!({"id":"later","thread_name":"Already named"}),
        ],
    );
    {
        let db = f.store.writer()?;
        crate::sessions::metadata::titles(&db, &f.origins)?;
        db.execute("UPDATE session SET delegated_parent_known=1,delegated_parent_session_key=?2 WHERE session_key=?1", rusqlite::params![root,child])?;
    }
    write(&f.codex, &[codex_meta("codex-root", None)]);
    let later = f.origins[0].path().join("later.jsonl");
    write(&later, &[codex_meta("later", None)]);
    ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(&[f.codex.clone(), later]),
        &AtomicBool::new(false),
    )?;
    let db = f.store.writer()?;
    let retained: (String, String) = db.query_row(
        "SELECT title,delegated_parent_session_key FROM session WHERE session_key=?1",
        [&root],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    assert_eq!(retained, ("Native root title".into(), child));
    crate::sessions::metadata::titles(&db, &f.origins)?;
    let title: String = db.query_row(
        "SELECT title FROM session WHERE thread_id='later'",
        [],
        |r| r.get(0),
    )?;
    assert_eq!(title, "Already named");
    Ok(())
}

#[test]
fn sessions_native_titles_resume_after_complete_lines_and_replay_a_rewrite() -> Result<()> {
    let f = fixture();
    scan(&f);
    let path = f.origins[0].local_home.join("session_index.jsonl");
    write(
        &path,
        &[json!({"id":"codex-root","thread_name":"First title"})],
    );
    let db = f.store.writer()?;
    let current = || {
        db.query_row(
            "SELECT title FROM session WHERE thread_id='codex-root'",
            [],
            |r| r.get::<_, String>(0),
        )
    };
    crate::sessions::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "First title");
    let mut file = OpenOptions::new().append(true).open(&path)?;
    file.write_all(b"\xff\n")?;
    write!(
        file,
        "{{\"id\":\"codex-root\",\"thread_name\":\"Append title\""
    )?;
    crate::sessions::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "First title");
    writeln!(file, "}}")?;
    crate::sessions::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "Append title");
    write(
        &path,
        &[json!({"id":"codex-root","thread_name":"Replacement title"})],
    );
    crate::sessions::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "Replacement title");
    Ok(())
}

#[test]
#[ignore]
fn sessions_rebuild_search_corpus() -> Result<()> {
    let manifest = PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_ORIGINS")?);
    let origins: Vec<Origin> = serde_json::from_slice(&std::fs::read(&manifest)?)?;
    let root = manifest.parent().unwrap();
    anyhow::ensure!(
        origins.iter().all(|o| o.local_home.starts_with(root)),
        "measurement requires copied inputs beside the manifest"
    );
    let path = PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?);
    anyhow::ensure!(
        path.starts_with(root),
        "measurement database must be beside the manifest"
    );
    let store = Store::open(path, crate::sessions::storage::Capacity::Host)?;
    let started = Instant::now();
    let outcome = ingest::scan(&store, &origins, &AtomicBool::new(false))?;
    {
        let db = store.writer()?;
        crate::sessions::metadata::titles(&db, &origins)?;
    }
    {
        let mut db = store.writer()?;
        while crate::sessions::index::rebuild_one(&mut db)? {}
        db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
    }
    let report = json!({"seconds":started.elapsed().as_secs_f64(),"outcome":outcome,"databaseBytes":store.path.metadata()?.len()});
    std::fs::write(
        std::env::var("RC_SESSIONS_MEASURE_REPORT")?,
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{report}");
    Ok(())
}

#[test]
fn sessions_conversations_excerpt_keeps_the_match_on_character_boundaries() {
    let f = fixture();
    scan(&f);
    let key = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer().unwrap();
        conversation_item(
            &db,
            &key,
            444,
            &format!("{} Malmö {}", "🦀".repeat(300), "å".repeat(300)),
            "assistant",
            None,
        );
    }
    let result = conversation_search(&f.store, "malmo", 1, Default::default());
    let excerpt = &result.conversations[0].hit.as_ref().unwrap().excerpt;
    assert!(excerpt.contains("Malmö"));
    assert!(excerpt.chars().count() <= 240);
}

#[test]
fn sessions_conversations_excerpt_finds_a_deep_prefix() {
    let f = fixture();
    scan(&f);
    let key = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer().unwrap();
        conversation_item(
            &db,
            &key,
            445,
            &format!(
                "{} DeepMalmöFlickering {}",
                "ordinary ".repeat(12000),
                "tail ".repeat(100)
            ),
            "assistant",
            None,
        );
    }
    let result = conversation_search(&f.store, "deepmalmoflick", 1, Default::default());
    let excerpt = &result.conversations[0].hit.as_ref().unwrap().excerpt;
    assert!(excerpt.contains("DeepMalmöFlickering"));
    assert!(excerpt.chars().count() <= 240);
}

#[test]
fn sessions_conversations_count_matches_without_bounded_excerpts() -> Result<()> {
    let f = fixture();
    scan(&f);
    let key = crate::sessions::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer()?;
        conversation_item(
            &db,
            &key,
            446,
            &format!("OversizeMatch {}", "a".repeat(1 << 20)),
            "assistant",
            None,
        );
        db.execute(
            "UPDATE session SET cwd='/OversizeMatch' WHERE session_key=?1",
            [&key],
        )?;
    }
    let result = conversation_search(&f.store, "oversizematch", 1, Default::default());
    assert!(!result.truncated);
    assert_eq!(result.conversations.len(), 1);
    let conversation = &result.conversations[0];
    assert!(!conversation.title_match);
    assert_eq!(conversation.hit_count, 1);
    assert!(conversation.hit.is_none());
    Ok(())
}

#[test]
fn sessions_locate_preserves_native_turn_and_checks_exact_source() -> Result<()> {
    let f = fixture();
    scan(&f);
    let db = f.store.reader()?;
    let key: String = db.query_row("SELECT item_key FROM item WHERE kind='tool_result' AND session_key LIKE '%codex-root' LIMIT 1", [], |r| r.get(0))?;
    let request = crate::sessions::locate::Request { item_key: key };
    let control = crate::sessions::store::ReadControl::new(
        Instant::now() + crate::sessions::conversations::DEADLINE,
    );
    let item = crate::sessions::locate::item(&db, &request, &control)?;
    assert_eq!(item.response.thread_id, "codex-root");
    assert_eq!(item.response.turn_id.as_deref(), Some("turn-1"));
    assert!(item.response.item_id.is_none() && item.response.turns_cursor.is_none());
    std::fs::write(&f.codex, "changed source\n")?;
    assert!(
        crate::sessions::locate::item(&db, &request, &control)
            .err()
            .unwrap()
            .to_string()
            .contains("source_changed")
    );
    assert!(
        serde_json::from_value::<crate::sessions::locate::Request>(
            json!({"itemKey":"x","unknown":true})
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn sessions_meaning_resolves_exact_native_id_and_folds_roots() -> Result<()> {
    let f = fixture();
    scan(&f);
    let db = f.store.reader()?;
    let hits = serde_json::from_value(json!([
        {"sessionId":"unknown","provider":"claude","excerpt":"skip"},
        {"sessionId":"codex-child","provider":"codex","excerpt":"child evidence"},
        {"sessionId":"codex-root","provider":"codex","excerpt":"duplicate root"},
        {"sessionId":"root","provider":"claude","excerpt":"Claude evidence"}
    ]))?;
    let result = serde_json::to_value(crate::sessions::meaning::resolve(&db, hits, 30)?)?;
    assert_eq!(result["conversations"].as_array().unwrap().len(), 2);
    assert_eq!(result["conversations"][0]["threadId"], "codex-root");
    assert_eq!(result["conversations"][0]["excerpt"], "child evidence");
    assert_eq!(result["conversations"][1]["threadId"], "claude_root");
    assert!(result["conversations"][1]["title"].is_null());
    Ok(())
}
