use super::{Origin, changes, cluster, ingest, mirror, query, store::Store};
use anyhow::Result;
use base64::Engine;
use futures_util::FutureExt;
use serde_json::{Value, json};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, atomic::AtomicBool};
use std::time::Instant;

struct Fixture {
    _directory: tempfile::TempDir,
    store: Store,
    origins: Vec<Origin>,
    codex: PathBuf,
    claude: PathBuf,
    sidecar: PathBuf,
}

fn write(path: &Path, records: &[Value]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        path,
        records.iter().map(|v| format!("{v}\n")).collect::<String>(),
    )
    .unwrap();
}

fn codex_meta(id: &str, parent: Option<&str>) -> Value {
    json!({"type":"session_meta","timestamp":"2026-10-27T10:00:00Z","payload":{"id":id,"cwd":"/fixture","source":{"subagent":{"thread_spawn":{"parent_thread_id":parent}}}}})
}

fn fixture() -> Fixture {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let origins: Vec<_> = ["codex", "claude"]
        .into_iter()
        .map(|provider| {
            let home = root.join(provider);
            Origin {
                host: "fixture".into(),
                provider: provider.into(),
                provider_home: home.clone(),
                local_home: home,
            }
        })
        .collect();
    let codex = origins[0].path().join("2026/10/27/root.jsonl");
    let claude = origins[1].path().join("project/root.jsonl");
    let sidecar = claude.with_extension("").join("tool-results/output.txt");
    std::fs::create_dir_all(sidecar.parent().unwrap()).unwrap();
    std::fs::write(
        &sidecar,
        format!(
            "{} sidecarmiddle {}",
            "a ".repeat(32768),
            "z ".repeat(32768)
        ),
    )
    .unwrap();
    write(
        &codex,
        &[
            codex_meta("codex-root", None),
            json!({"type":"event_msg","timestamp":"2026-10-27T10:00:00Z","payload":{"type":"task_started","turn_id":"turn-1"}}),
            json!({"type":"turn_context","payload":{"turn_id":"turn-1","model":"fixture-model","effort":"high"}}),
            json!({"type":"response_item","timestamp":"2026-10-27T10:00:01Z","payload":{"type":"function_call","call_id":"call-1","name":"exec_command","arguments":"{\"cmd\":\"cat /fixture/skills/agents/SKILL.md\"}"}}),
            json!({"type":"response_item","timestamp":"2026-10-27T10:00:02Z","payload":{"type":"function_call_output","call_id":"call-1","output":format!("{} codexmiddle {}\nProcess exited with code 0\n","a ".repeat(65536),"z ".repeat(65536))}}),
            json!({"type":"response_item","timestamp":"2026-10-27T10:00:03Z","payload":{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,aGVsbG8="}]}}),
        ],
    );
    write(
        &codex.with_file_name("child.jsonl"),
        &[codex_meta("codex-child", Some("codex-root"))],
    );
    write(
        &claude,
        &[
            json!({"type":"user","sessionId":"root","uuid":"prompt-1","timestamp":"2026-10-27T10:00:00Z","cwd":"/fixture","message":{"role":"user","content":"Inspect fixture"}}),
            json!({"type":"assistant","sessionId":"root","uuid":"assistant-1","timestamp":"2026-10-27T10:00:01Z","message":{"model":"fixture-model","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"/fixture/skills/agents/SKILL.md"}}]}}),
            json!({"type":"user","sessionId":"root","uuid":"result-1","timestamp":"2026-10-27T10:00:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":false,"content":format!("<persisted-output>\nFull output saved to: {}\n</persisted-output>",sidecar.display())}]}}),
            json!({"type":"user","sessionId":"root","uuid":"image-1","timestamp":"2026-10-27T10:00:03Z","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGVsbG8="}}]}}),
        ],
    );
    write(
        &claude
            .with_extension("")
            .join("subagents/agent-child.jsonl"),
        &[
            json!({"type":"user","sessionId":"root","uuid":"child-prompt","timestamp":"2026-10-27T10:00:00Z","message":{"content":"Native child"}}),
        ],
    );
    let store = Store::open(root.join("state/catalog.sqlite3")).unwrap();
    Fixture {
        _directory: directory,
        store,
        origins,
        codex,
        claude,
        sidecar,
    }
}

fn scan(f: &Fixture) -> Value {
    ingest::scan(&f.store, &f.origins, &AtomicBool::new(false)).unwrap()
}
fn search(store: &Store, term: &str) -> Value {
    query::search(
        &store.reader().unwrap(),
        &query::Search {
            query: term.into(),
            ..Default::default()
        },
    )
    .unwrap()
}

#[test]
fn sessions_evidence_survives_append_rewrite_and_exact_paging() {
    let f = fixture();
    assert_eq!(scan(&f)["parseFailures"], 0);
    for term in ["codexmiddle", "sidecarmiddle"] {
        let found = search(&f.store, term);
        assert_eq!(found["hits"].as_array().unwrap().len(), 1);
        let key = found["hits"][0]["itemKey"].as_str().unwrap();
        let raw = std::fs::read(if term == "codexmiddle" {
            &f.codex
        } else {
            &f.claude
        })
        .unwrap();
        let reference: String = f
            .store
            .reader()
            .unwrap()
            .query_row(
                "SELECT source_ref FROM item WHERE item_key=?1",
                [key],
                |r| r.get(0),
            )
            .unwrap();
        let reference: query::SourceRef = serde_json::from_str(&reference).unwrap();
        let mut actual = Vec::new();
        let mut offset = 0;
        loop {
            let page = query::read(
                &f.store.reader().unwrap(),
                query::ReadRequest {
                    target: key.into(),
                    offset,
                    length: Some(8191),
                    dependency: None,
                },
            )
            .unwrap();
            actual.extend(
                base64::engine::general_purpose::STANDARD
                    .decode(page["base64"].as_str().unwrap())
                    .unwrap(),
            );
            match page["nextOffset"].as_u64() {
                Some(next) => offset = next,
                None => break,
            }
        }
        assert_eq!(
            actual,
            raw[reference.offset as usize..(reference.offset + reference.length) as usize]
        );
    }
    let db = f.store.reader().unwrap();
    let children: i64 = db
        .query_row(
            "SELECT count(*) FROM session WHERE parent_session_key IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(children, 2);
    let images:i64=db.query_row("SELECT count(*) FROM item WHERE json_array_length(json_extract(source_ref,'$.images'))>0",[],|r|r.get(0)).unwrap();
    assert_eq!(images, 2);
    let skills:i64=db.query_row("SELECT count(DISTINCT session_key) FROM v_skill_use WHERE skill='agents' AND outcome='ok'",[],|r|r.get(0)).unwrap();
    assert_eq!(skills, 2);
    let cursor = changes::cursor(&db).unwrap();
    drop(db);
    assert_eq!(scan(&f)["ingested"], 0);
    assert_eq!(changes::cursor(&f.store.reader().unwrap()).unwrap(), cursor);
    let appended = json!({"type":"response_item","timestamp":"2026-10-27T10:00:04Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"appendneedle"}]}});
    writeln!(
        OpenOptions::new().append(true).open(&f.codex).unwrap(),
        "{appended}"
    )
    .unwrap();
    scan(&f);
    assert_eq!(
        search(&f.store, "appendneedle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let old_key = search(&f.store, "codexmiddle")["hits"][0]["itemKey"]
        .as_str()
        .unwrap()
        .to_owned();
    let rewritten = std::fs::read_to_string(&f.codex)
        .unwrap()
        .replace("codexmiddle", "rewritemid!");
    std::fs::write(&f.codex, rewritten).unwrap();
    assert!(
        query::read(
            &f.store.reader().unwrap(),
            query::ReadRequest {
                target: old_key,
                offset: 0,
                length: None,
                dependency: None
            }
        )
        .is_err()
    );
    scan(&f);
    assert!(
        search(&f.store, "codexmiddle")["hits"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        search(&f.store, "rewritemid!")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    std::fs::write(&f.sidecar, "sidecarrewritten").unwrap();
    scan(&f);
    assert_eq!(
        search(&f.store, "sidecarrewritten")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    std::fs::remove_file(&f.claude).unwrap();
    scan(&f);
    assert_eq!(
        search(&f.store, "sidecarrewritten")["hits"][0]["sourceDeleted"],
        true
    );
}

#[test]
fn sessions_feed_restart_expiry_and_atomic_rejection() {
    let f = fixture();
    scan(&f);
    let db = f.store.reader().unwrap();
    let cursor = changes::cursor(&db).unwrap();
    drop(db);
    let reopened = Store::open(f.store.path.clone()).unwrap();
    assert!(
        changes::read(
            &reopened.reader().unwrap(),
            changes::Request {
                cursor: Some(cursor.clone()),
                limit: None
            }
        )
        .unwrap()["rows"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    writeln!(
        OpenOptions::new().append(true).open(&f.codex).unwrap(),
        "{{malformed}}"
    )
    .unwrap();
    assert_eq!(scan(&f)["parseFailures"], 1);
    assert_eq!(
        search(&f.store, "codexmiddle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let writer = f.store.writer().unwrap();
    writer
        .execute("UPDATE change SET committed_at='2000-01-01T00:00:00Z'", [])
        .unwrap();
    changes::prune(&writer).unwrap();
    let error = changes::read(
        &reopened.reader().unwrap(),
        changes::Request {
            cursor: Some(cursor),
            limit: None,
        },
    )
    .unwrap_err();
    assert!(error.to_string().starts_with("cursor_expired:"));
}

#[test]
fn sessions_skill_catalog_deduplicates_provider_symlinks() {
    let root = tempfile::tempdir().unwrap();
    let actual = root.path().join("shared");
    std::fs::create_dir_all(actual.join("agents")).unwrap();
    std::fs::write(actual.join("agents/SKILL.md"), "fixture").unwrap();
    let roots: Vec<_> = ["codex", "agents", "claude"]
        .into_iter()
        .map(|name| {
            let path = root.path().join(name);
            std::os::unix::fs::symlink(&actual, &path).unwrap();
            path
        })
        .collect();
    let store = Store::open(root.path().join("state/catalog.sqlite3")).unwrap();
    let db = store.writer().unwrap();
    ingest::catalog(&db, &roots).unwrap();
    assert_eq!(
        db.query_row("SELECT count(*) FROM skill WHERE present=1", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    let cursor = changes::cursor(&db).unwrap();
    ingest::catalog(&db, &roots).unwrap();
    assert_eq!(changes::cursor(&db).unwrap(), cursor);
}

#[test]
fn sessions_timestamps_preserve_fractional_order() {
    let whole = super::timestamp("2026-10-28T10:00:00Z").unwrap();
    let fraction = super::timestamp("2026-10-28T11:00:00.1+01:00").unwrap();
    assert!(whole < fraction);
    assert_eq!(fraction, "2026-10-28T10:00:00.100000000Z");
}

#[test]
fn sessions_schema_mismatch_rebuilds_projection_and_expires_cursor() {
    let f = fixture();
    scan(&f);
    let raw = std::fs::read(&f.codex).unwrap();
    let cursor = changes::cursor(&f.store.reader().unwrap()).unwrap();
    f.store
        .writer()
        .unwrap()
        .pragma_update(None, "user_version", 99)
        .unwrap();
    Store::open(f.store.path.clone()).unwrap();
    assert!(
        changes::read(
            &f.store.reader().unwrap(),
            changes::Request {
                cursor: Some(cursor),
                limit: None
            }
        )
        .is_err()
    );
    assert!(
        query::inventory(&f.store.reader().unwrap(), None, 1000)
            .unwrap()
            .sessions
            .is_empty()
    );
    scan(&f);
    assert_eq!(
        query::inventory(&f.store.reader().unwrap(), None, 1000)
            .unwrap()
            .sessions
            .len(),
        4
    );
    assert_eq!(std::fs::read(&f.codex).unwrap(), raw);
}

#[test]
fn sessions_spawn_then_resolve_catches_up_before_worker_scan() {
    let f = fixture();
    scan(&f);
    let new = f.codex.with_file_name("newly-spawned.jsonl");
    write(
        &new,
        &[
            codex_meta("newly-spawned", None),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"afteridentityneedle"}]}}),
        ],
    );
    ingest::refresh_inventory(&f.store, &f.origins).unwrap();
    let page = query::inventory(&f.store.reader().unwrap(), None, 1000).unwrap();
    assert!(page.sessions.iter().any(|h| h.thread_id == "newly-spawned"));
    scan(&f);
    assert_eq!(
        search(&f.store, "afteridentityneedle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    std::fs::write(f.codex.with_file_name("pending-identity.jsonl"), b"{").unwrap();
    assert!(ingest::refresh_inventory(&f.store, &f.origins).is_err());
}

#[test]
fn sessions_inventory_pages_exact_provider_headers() {
    let f = fixture();
    scan(&f);
    let db = f.store.reader().unwrap();
    let first = query::inventory(&db, None, 2).unwrap();
    assert_eq!(first.sessions.len(), 2);
    let second = query::inventory(&db, first.cursor.as_deref(), 2).unwrap();
    assert_eq!(second.sessions.len(), 2);
    assert!(second.cursor.is_none());
    let headers: Vec<_> = first.sessions.into_iter().chain(second.sessions).collect();
    assert!(
        headers
            .iter()
            .all(|h| h.host_id == "fixture" && h.source_present)
    );
    assert!(
        headers
            .iter()
            .any(|h| h.thread_id == "codex-child" && h.parent_session_key.is_some())
    );
    assert!(
        headers
            .iter()
            .any(|h| h.thread_id == "claude:root:child" && h.parent_session_key.is_some())
    );
}

#[test]
fn sessions_sql_is_read_only_and_bounded() {
    let f = fixture();
    scan(&f);
    for sql in [
        "DELETE FROM item",
        "ATTACH ':memory:' AS evil",
        "PRAGMA query_only=OFF",
        "SELECT load_extension('/tmp/nonexistent')",
        "SELECT 1; SELECT 2",
    ] {
        assert!(
            query::sql(&f.store.reader().unwrap(), sql).is_err(),
            "{sql}"
        );
    }
    let result=query::sql(&f.store.reader().unwrap(),"WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10001) SELECT x FROM n").unwrap();
    assert_eq!(result["rows"].as_array().unwrap().len(), 10000);
    assert_eq!(result["truncated"], true);
    assert!(query::sql(&f.store.reader().unwrap(), "SELECT randomblob(100000000)").is_err());
    let result = query::sql(
        &f.store.reader().unwrap(),
        "SELECT name FROM sqlite_schema WHERE type='table'",
    )
    .unwrap();
    assert!(!result["rows"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn sessions_mirror_preserves_sidecars_and_refuses_over_budget() {
    let f = fixture();
    scan(&f);
    let destination = tempfile::tempdir().unwrap();
    let target = Store::open(destination.path().join("state/catalog.sqlite3")).unwrap();
    let peer = f.store.clone();
    let call: mirror::Call = Arc::new(move |method: &'static str, params: Value| {
        let peer = peer.clone();
        async move {
            match method {
                "sessions/mirror/list" => mirror::list(
                    &peer,
                    "fixture",
                    params["cursor"].as_str().map(str::to_owned),
                ),
                "sessions/mirror/fetch" => {
                    mirror::fetch(&peer, "fixture", serde_json::from_value(params)?)
                }
                _ => anyhow::bail!("Unexpected member method"),
            }
        }
        .boxed()
    });
    assert_eq!(
        mirror::sync(
            &target,
            "fixture",
            call.clone(),
            tokio_util::sync::CancellationToken::new()
        )
        .await
        .unwrap()["complete"],
        true
    );
    assert_eq!(
        search(&target, "sidecarmiddle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let previous: Option<String> = target
        .reader()
        .unwrap()
        .query_row(
            "SELECT complete_through FROM coverage WHERE origin_host='fixture'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    std::fs::remove_file(&f.sidecar).unwrap();
    scan(&f);
    assert_eq!(
        mirror::sync(
            &target,
            "fixture",
            call.clone(),
            tokio_util::sync::CancellationToken::new()
        )
        .await
        .unwrap()["complete"],
        false
    );
    let watermark: Option<String> = target
        .reader()
        .unwrap()
        .query_row(
            "SELECT complete_through FROM coverage WHERE origin_host='fixture'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(watermark.is_some());
    assert_eq!(watermark, previous);
    assert!(mirror::admit(50 << 30, 1, 100 << 30, 100 << 30).is_err());
    assert!(mirror::admit(0, 1, 19 << 30, 100 << 30).is_err());
    assert!(mirror::admit(0, 1, 30 << 30, 400 << 30).is_err());
    assert!(mirror::admit(0, 1, 50 << 30, 400 << 30).is_ok());
}

#[tokio::test]
async fn sessions_cluster_search_reports_unreachable_members() {
    let call: cluster::MemberCall = Arc::new(|host, method, params| {
        async move {
            assert_eq!(method, "sessions/search");
            assert_eq!(params["local"], true);
            if host == "away" {
                anyhow::bail!("offline");
            }
            Ok(json!({"hits":[{"itemKey":"peer:item:1","host":host}],"cursor":null}))
        }
        .boxed()
    });
    let result = cluster::search(
        json!({"hits":[],"cursor":null}),
        vec!["peer".into(), "away".into()],
        query::Search {
            query: "middle".into(),
            ..Default::default()
        },
        call,
    )
    .await
    .unwrap();
    assert_eq!(result["hits"].as_array().unwrap().len(), 1);
    assert!(
        result["coverage"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["hostId"] == "away" && c["state"] == "unreachable")
    );
}

#[test]
#[ignore]
fn sessions_measure_corpus() -> Result<()> {
    let manifest = std::env::var("RC_SESSIONS_MEASURE_ORIGINS")?;
    let origins: Vec<Origin> = serde_json::from_slice(&std::fs::read(manifest)?)?;
    let store = Store::open(PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?))?;
    let started = Instant::now();
    let outcome = ingest::scan(&store, &origins, &AtomicBool::new(false))?;
    let ingest_seconds = started.elapsed().as_secs_f64();
    println!(
        "{}",
        json!({"phase":"ingested","seconds":ingest_seconds,"outcome":outcome})
    );
    let db = store.writer()?;
    db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    let normalized_bytes: i64 =
        db.query_row("SELECT coalesce(sum(text_bytes),0) FROM item", [], |r| {
            r.get(0)
        })?;
    let sessions: i64 = db.query_row("SELECT count(*) FROM session", [], |r| r.get(0))?;
    ingest::catalog(
        &db,
        &[
            PathBuf::from(std::env::var("HOME")?).join(".agents/skills"),
            PathBuf::from(std::env::var("HOME")?).join(".claude/skills"),
        ],
    )?;
    let skill_started = Instant::now();
    let unused_query = query::rows(
        &db,
        "SELECT s.name,count(DISTINCT u.session_key) AS sessions FROM skill s LEFT JOIN v_skill_use u ON u.skill=s.name AND u.outcome='ok' AND julianday(u.at)>=julianday('now','-14 days') WHERE s.present=1 AND julianday(s.first_seen)<=julianday('now','-14 days') GROUP BY s.name ORDER BY sessions ASC",
        [],
    )?;
    std::hint::black_box(unused_query);
    let unused_query_seconds = skill_started.elapsed().as_secs_f64();
    let agents: i64 = db.query_row(
        "SELECT count(DISTINCT session_key) FROM v_skill_use WHERE skill='agents' AND outcome='ok'",
        [],
        |r| r.get(0),
    )?;
    let pair_programming:i64=db.query_row("SELECT count(DISTINCT session_key) FROM v_skill_use WHERE skill='pair-programming' AND outcome='ok'",[],|r|r.get(0))?;
    let observed_agents: i64 = db.query_row(
        "SELECT count(DISTINCT session_key) FROM v_skill_use WHERE skill='agents'",
        [],
        |r| r.get(0),
    )?;
    let observed_pair: i64 = db.query_row(
        "SELECT count(DISTINCT session_key) FROM v_skill_use WHERE skill='pair-programming'",
        [],
        |r| r.get(0),
    )?;
    let roots: i64 = db.query_row(
        "SELECT count(*) FROM session WHERE parent_session_key IS NULL",
        [],
        |r| r.get(0),
    )?;
    let root_agents:i64=db.query_row("SELECT count(DISTINCT u.session_key) FROM v_skill_use u JOIN session s USING(session_key) WHERE skill='agents' AND s.parent_session_key IS NULL",[],|r|r.get(0))?;
    let skill_seconds = skill_started.elapsed().as_secs_f64();
    let fts_bytes: Option<i64> = db
        .query_row(
            "SELECT sum(pgsize) FROM dbstat WHERE name LIKE 'item_fts_%'",
            [],
            |r| r.get(0),
        )
        .ok();
    drop(db);
    let mut times = Vec::new();
    for _ in 0..10 {
        for term in [
            "SKILL.md",
            "Process exited",
            "codex-threads",
            "permission",
            "Continue target",
            "pair-programming",
            "PID start time",
            "remote-coder",
            "agents",
            "FileRevision",
        ] {
            let started = Instant::now();
            let result = query::search(
                &store.reader()?,
                &query::Search {
                    query: term.into(),
                    limit: Some(50),
                    ..Default::default()
                },
            )?;
            std::hint::black_box(result);
            times.push(started.elapsed().as_secs_f64() * 1000.0);
        }
    }
    times.sort_by(f64::total_cmp);
    let lag_fixture = fixture();
    let mut catchup_origins = origins.clone();
    catchup_origins.extend(lag_fixture.origins.clone());
    ingest::scan(&store, &catchup_origins, &AtomicBool::new(false))?;
    let started = Instant::now();
    writeln!(
        OpenOptions::new().append(true).open(&lag_fixture.codex)?,
        "{}",
        json!({"type":"response_item","timestamp":"2026-10-27T11:00:00Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ingestlagneedle"}]}})
    )?;
    ingest::scan(&store, &catchup_origins, &AtomicBool::new(false))?;
    let ingest_lag_ms = started.elapsed().as_secs_f64() * 1000.0;
    let report = json!({"normalizedBytes":normalized_bytes,"databaseBytes":store.path.metadata()?.len(),"ftsBytes":fts_bytes,"ingestSeconds":ingest_seconds,"searchP95Ms":times[94],"skillQuerySeconds":skill_seconds,"unusedSkillQuerySeconds":unused_query_seconds,"incrementalIngestMs":ingest_lag_ms,"pollIntervalMs":2000,"sessions":sessions,"agentsSkillSessions":agents,"observedAgentsSessions":observed_agents,"observedPairProgrammingSessions":observed_pair,"rootSessions":roots,"rootAgentsSessions":root_agents,"agentsSkillPercent":100.0*agents as f64/sessions as f64,"pairProgrammingSessions":pair_programming,"outcome":outcome});
    std::fs::write(
        std::env::var("RC_SESSIONS_MEASURE_REPORT")?,
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{report}");
    Ok(())
}
