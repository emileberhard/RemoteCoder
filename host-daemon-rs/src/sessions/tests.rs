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
    assert_eq!(
        scan(&f)["parseFailures"],
        0,
        "{:?}",
        f.store
            .reader()
            .unwrap()
            .prepare("SELECT failure FROM source WHERE failure IS NOT NULL")
            .unwrap()
            .query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
    );
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
    assert!(
        search(&f.store, "sidecarrewritten")["hits"]
            .as_array()
            .unwrap()
            .is_empty()
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
fn sessions_raw_session_read_and_missing_address() {
    let f = fixture();
    scan(&f);
    let result = query::read(
        &f.store.reader().unwrap(),
        query::ReadRequest {
            target: "codex-root".into(),
            offset: 0,
            length: Some(4 << 20),
            dependency: None,
        },
    )
    .unwrap();
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(result["base64"].as_str().unwrap())
            .unwrap(),
        std::fs::read(&f.codex).unwrap()
    );
    let error = query::read(
        &f.store.reader().unwrap(),
        query::ReadRequest {
            target: "missing-session".into(),
            offset: 0,
            length: None,
            dependency: None,
        },
    )
    .unwrap_err();
    assert_eq!(super::exit_code(&super::error_data(&error)), 3);
}

#[test]
fn sessions_errors_keep_their_cli_exit_class() {
    for (message, code) in [
        ("not_found: source", 3),
        ("capacity: index", 4),
        ("unavailable: ingest", 5),
        ("unsupported: peer", 7),
        ("cursor_expired: snapshot", 8),
        ("invalid query", 2),
    ] {
        assert_eq!(
            super::exit_code(&super::error_data(&anyhow::anyhow!(message))),
            code
        );
    }
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
fn sessions_previous_schema_rebuilds_projection_and_expires_cursor() {
    let f = fixture();
    scan(&f);
    let raw = std::fs::read(&f.codex).unwrap();
    let cursor = changes::cursor(&f.store.reader().unwrap()).unwrap();
    f.store
        .writer()
        .unwrap()
        .pragma_update(None, "user_version", super::SCHEMA_VERSION - 1)
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
    let worker = super::worker::Worker::start(f.store.clone(), f.origins.clone()).unwrap();
    let new = f.codex.with_file_name("newly-spawned.jsonl");
    write(
        &new,
        &[
            codex_meta("newly-spawned", None),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"afteridentityneedle"}]}}),
        ],
    );
    ingest::refresh_inventory(&f.store).unwrap();
    let page = query::inventory(&f.store.reader().unwrap(), None, 1000).unwrap();
    assert!(page.sessions.iter().any(|h| h.thread_id == "newly-spawned"));
    worker.stop().unwrap();
    scan(&f);
    assert_eq!(
        search(&f.store, "afteridentityneedle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let next = Store::open(f.store.path.clone()).unwrap();
    let worker = super::worker::Worker::start(next.clone(), f.origins.clone()).unwrap();
    std::fs::write(f.codex.with_file_name("pending-identity.jsonl"), b"{").unwrap();
    assert!(ingest::refresh_inventory(&next).is_err());
    worker.stop().unwrap();
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
    std::fs::remove_dir_all(f.claude.parent().unwrap()).unwrap();
    scan(&f);
    mirror::sync(
        &target,
        "fixture",
        call,
        tokio_util::sync::CancellationToken::new(),
    )
    .await
    .unwrap();
    let remaining: i64 = target
        .reader()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM session WHERE provider='claude'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(remaining, 0);

    assert!(super::storage::admit(64 << 30, 1, 100 << 30).is_err());
    assert!(super::storage::admit(0, 1, 19 << 30).is_err());
    assert!(super::storage::admit(0, 1, 30 << 30).is_ok());
    assert!(super::storage::admit(0, 1, 50 << 30).is_ok());
}

#[tokio::test]
async fn sessions_cluster_coverage_preserves_link_failure_classes() {
    let call: cluster::MemberCall = Arc::new(|host, _, _| {
        async move {
            let class = match host.as_str() {
                "unsupported" => crate::wire::cluster::ErrorClass::Unsupported,
                "refused" => crate::wire::cluster::ErrorClass::Refused,
                _ => crate::wire::cluster::ErrorClass::Unavailable,
            };
            Err(crate::cluster::link::LinkError {
                class,
                transmitted: false,
                message: host,
            }
            .into())
        }
        .boxed()
    });
    let result = cluster::search(
        "local-uuid",
        json!({"hits":[],"cursor":null}),
        vec!["unsupported".into(), "refused".into(), "unreachable".into()],
        query::Search {
            query: "fixture".into(),
            ..Default::default()
        },
        call,
    )
    .await
    .unwrap();
    let coverage = result["coverage"].as_array().unwrap();
    assert!(
        coverage
            .iter()
            .any(|row| row["hostId"] == "local-uuid" && row["state"] == "ok")
    );
    for state in ["unsupported", "refused", "unreachable"] {
        assert!(
            coverage
                .iter()
                .any(|row| row["hostId"] == state && row["state"] == state)
        );
    }
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
        "local-uuid",
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
    if let Ok(mode) = std::env::var("RC_SESSIONS_MEASURE_IDLE") {
        return super::idle_measurement::run(&store, &origins, &mode);
    }
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

#[test]
#[ignore]
fn sessions_audit_rejected_sources() -> Result<()> {
    let origins: Vec<Origin> = serde_json::from_slice(&std::fs::read(std::env::var(
        "RC_SESSIONS_MEASURE_ORIGINS",
    )?)?)?;
    let store = Store::open(PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?))?;
    let mut db = store.writer()?;
    let mut errors = std::collections::BTreeMap::<String, usize>::new();
    for origin in origins.iter().filter(|o| o.provider == "claude") {
        for path in ingest::files(origin)? {
            let known: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM source WHERE origin_host=?1 AND path=?2)",
                rusqlite::params![origin.host, origin.original(&path)?.to_string_lossy()],
                |r| r.get(0),
            )?;
            if !known
                && let Err(error) = ingest::ingest(&mut db, origin, &path, &AtomicBool::new(false))
            {
                *errors.entry(format!("{error:#}")).or_default() += 1;
            }
        }
    }
    println!("{}", serde_json::to_string(&errors)?);
    Ok(())
}

#[test]
fn sessions_keep_owning_identity_and_binary_evidence() {
    let f = fixture();
    let owner = "00000000-0000-0000-0000-000000000001";
    let path = f.codex.with_file_name(format!("rollout-{owner}.jsonl"));
    write(
        &path,
        &[codex_meta(owner, None), codex_meta("inherited-id", None)],
    );
    std::fs::write(&f.sidecar, [0xff, 0xfe, 0x00, 0x80]).unwrap();
    assert_eq!(scan(&f)["parseFailures"], 0);
    let db = f.store.reader().unwrap();
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM session WHERE thread_id=?1",
            [owner],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM session WHERE thread_id='inherited-id'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    let key=db.query_row("SELECT item_key FROM tool_result r JOIN item i USING(item_key) JOIN session s USING(session_key) WHERE s.provider='claude'",[],|r|r.get::<_,String>(0)).unwrap();
    let result = query::read(
        &db,
        query::ReadRequest {
            target: key,
            offset: 0,
            length: Some(64),
            dependency: Some(f.sidecar.to_string_lossy().into_owned()),
        },
    )
    .unwrap();
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(result["base64"].as_str().unwrap())
            .unwrap(),
        [0xff, 0xfe, 0x00, 0x80]
    );
}

#[test]
fn sessions_normalize_protocol_outcomes_without_guessing_text() {
    assert_eq!(ingest::outcome(&Value::Null,"Script completed\nWall time: 1\nOutput:\n{\"chunk_id\":\"fixture\",\"exit_code\":0,\"output\":\"fixture\"}").1,Some(0));
    assert_eq!(
        ingest::outcome(&Value::Null, "Transcript mentions exit_code: 0").1,
        None
    );
    let f = fixture();
    let mut records: Vec<Value> = std::fs::read_to_string(&f.claude)
        .unwrap()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect();
    records[2]["message"]["content"][0]
        .as_object_mut()
        .unwrap()
        .remove("is_error");
    write(&f.claude, &records);
    scan(&f);
    assert_eq!(f.store.reader().unwrap().query_row("SELECT count(*) FROM skill_observation u JOIN session s USING(session_key) WHERE s.provider='claude' AND outcome='ok'",[],|r|r.get::<_,i64>(0)).unwrap(),1);
}

#[test]
fn sessions_budget_counts_catalog_wal_and_temporary_mirrors() {
    let f = fixture();
    let root = f.store.path.parent().unwrap();
    let storage = &f.store.storage;
    let before = storage.usage().unwrap().used_bytes;
    let partial = root.join("mirror.partial");
    storage
        .mutate(&[&partial], 4096, || {
            Ok(std::fs::write(&partial, vec![0; 4096])?)
        })
        .unwrap();
    assert!((before + 4096..=before + 4200).contains(&storage.usage().unwrap().used_bytes));
    let lease = storage.lease(1).unwrap();
    assert!(f.store.writer().is_err());
    drop(lease);
    assert!(f.store.writer().is_ok());
}

#[test]
fn sessions_mirror_role_defaults_off() {
    let f = fixture();
    assert!(!mirror::role(&f.store.path).unwrap());
    let path = f
        .store
        .path
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mirror-role.json");
    std::fs::write(&path, r#"{"enabled":true}"#).unwrap();
    assert!(mirror::role(&f.store.path).unwrap());
    std::fs::write(&path, r#"{"enabled":"yes"}"#).unwrap();
    assert!(mirror::role(&f.store.path).is_err());
}

#[test]
fn sessions_accounting_recovers_dirty_writes_without_request_walks() {
    let f = fixture();
    let storage = &f.store.storage;
    let root = f.store.path.parent().unwrap();
    let before = storage.usage().unwrap().used_bytes;
    std::fs::write(root.join("orphan.partial"), vec![0; 8192]).unwrap();
    assert_eq!(storage.usage().unwrap().used_bytes, before);
    std::fs::write(root.join(".accounting.dirty"), b"1").unwrap();
    assert_eq!(
        storage.usage().unwrap().stale_reason,
        Some("accounting_incomplete")
    );
    drop(storage.lease(0).unwrap());
    assert!(storage.usage().unwrap().used_bytes >= before + 8192);
    assert_eq!(storage.usage().unwrap().stale_reason, None);
    let path = root.join("failed.partial");
    let error = storage.mutate(&[&path], 1024, || -> Result<()> {
        std::fs::write(&path, vec![0; 1024])?;
        anyhow::bail!("fixture interrupted after write")
    });
    assert!(error.is_err());
    assert!(!root.join(".accounting.dirty").exists());
}

#[test]
#[ignore]
fn sessions_measure_populated_mirror() -> Result<()> {
    let store = Store::open(PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?))?;
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
            std::hint::black_box(query::search(
                &store.reader()?,
                &query::Search {
                    query: term.into(),
                    limit: Some(50),
                    ..Default::default()
                },
            )?);
            times.push(started.elapsed().as_secs_f64() * 1000.0);
        }
    }
    times.sort_by(f64::total_cmp);
    let db = store.reader()?;
    let started = Instant::now();
    let counts = query::rows(
        &db,
        "SELECT s.origin_host,CASE WHEN ?1 THEN 'top_level' ELSE 'all' END,count(DISTINCT s.session_key),count(DISTINCT CASE WHEN u.skill='agents' THEN s.session_key END),count(DISTINCT CASE WHEN u.skill='agents' AND u.outcome='ok' THEN s.session_key END),count(DISTINCT CASE WHEN u.skill='pair-programming' THEN s.session_key END) FROM session s LEFT JOIN skill_observation u USING(session_key) WHERE s.origin_host IN ('mini','macbook') AND (?1=0 OR s.parent_session_key IS NULL) GROUP BY s.origin_host",
        [0],
    )?;
    let roots = query::rows(
        &db,
        "SELECT s.origin_host,'top_level',count(DISTINCT s.session_key),count(DISTINCT CASE WHEN u.skill='agents' THEN s.session_key END),count(DISTINCT CASE WHEN u.skill='agents' AND u.outcome='ok' THEN s.session_key END),count(DISTINCT CASE WHEN u.skill='pair-programming' THEN s.session_key END) FROM session s LEFT JOIN skill_observation u USING(session_key) WHERE s.origin_host IN ('mini','macbook') AND s.parent_session_key IS NULL GROUP BY s.origin_host",
        [],
    )?;
    let skill_query_ms = started.elapsed().as_secs_f64() * 1000.0;
    let report = json!({"searchP95Ms":times[94],"skillQueryMs":skill_query_ms,"all":counts,"topLevel":roots,"storage":store.storage.usage()?});
    std::fs::write(
        std::env::var("RC_SESSIONS_MEASURE_REPORT")?,
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{report}");
    Ok(())
}

#[test]
fn sessions_scoped_reconcile_reclaims_deleted_sources_and_updates_sidecars() {
    let f = fixture();
    scan(&f);
    std::fs::remove_file(&f.codex).unwrap();
    std::fs::write(&f.sidecar, "changedsidecarevidence").unwrap();
    let paths = [f.codex.clone(), f.sidecar.parent().unwrap().to_owned()];
    let result = ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(&paths),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(result["parseFailures"], 0);
    assert!(
        search(&f.store, "codexmiddle")["hits"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        search(&f.store, "changedsidecarevidence")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let db = f.store.reader().unwrap();
    let remaining: i64 = db
        .query_row("SELECT count(*) FROM session", [], |r| r.get(0))
        .unwrap();
    assert_eq!(remaining, 3);
    let deleted: i64 = db
        .query_row(
            "SELECT count(*) FROM source WHERE local_path=?1",
            [f.codex.to_string_lossy().as_ref()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(deleted, 0);
    let tombstones: i64 = db
        .query_row(
            "SELECT count(*) FROM change WHERE entity='session' AND op='tombstone'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(tombstones > 0);
    drop(db);
    std::fs::write(&f.codex, "malformed outside the scoped subtree\n").unwrap();
    std::fs::write(&f.sidecar, "anotherchangedsidecar").unwrap();
    ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(&[f.claude.parent().unwrap().to_owned()]),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(
        search(&f.store, "anotherchangedsidecar")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let count: i64 = f
        .store
        .reader()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM source WHERE local_path=?1",
            [f.codex.to_string_lossy().as_ref()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn sessions_missing_provider_root_preserves_rows_without_tombstones() {
    let f = fixture();
    scan(&f);
    let counts = || {
        f.store.reader().unwrap().query_row(
            "SELECT (SELECT count(*) FROM session), (SELECT count(*) FROM source), (SELECT count(*) FROM change WHERE op='tombstone')",
            [],
            |row| Ok((row.get::<_,i64>(0)?, row.get::<_,i64>(1)?, row.get::<_,i64>(2)?)),
        ).unwrap()
    };
    let before = counts();
    std::fs::remove_dir_all(f.origins[0].path()).unwrap();
    scan(&f);
    assert_eq!(counts(), before);
    ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(&[f.origins[0].path()]),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(counts(), before);
    let reason: String = f
        .store
        .reader()
        .unwrap()
        .query_row(
            "SELECT stale_reason FROM coverage WHERE origin_host='fixture'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(reason, "provider_unavailable");
}

#[test]
fn sessions_inventory_accepts_known_exact_duplicates_without_transferring_ownership() {
    let f = fixture();
    scan(&f);
    let duplicate = f.codex.with_file_name("duplicate.jsonl");
    std::fs::copy(&f.codex, &duplicate).unwrap();
    assert_eq!(scan(&f)["parseFailures"], 1);
    let mut db = f.store.writer().unwrap();
    let owner: i64 = db
        .query_row(
            "SELECT source_id FROM session WHERE thread_id='codex-root'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    ingest::header(&mut db, &f.origins[0], &duplicate, &AtomicBool::new(false)).unwrap();
    let after: i64 = db
        .query_row(
            "SELECT source_id FROM session WHERE thread_id='codex-root'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(owner, after);
    let failures: i64 = db
        .query_row(
            "SELECT count(*) FROM source WHERE failure IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(failures, 1);
    let headers: i64 = db
        .query_row("SELECT count(*) FROM session", [], |row| row.get(0))
        .unwrap();
    assert_eq!(headers, 4);
}

#[test]
fn sessions_claude_filename_owns_inherited_queue_identity() {
    let f = fixture();
    let path = f.claude.with_file_name("fork.jsonl");
    write(
        &path,
        &[
            json!({"type":"queue-operation","sessionId":"root"}),
            json!({"type":"user","sessionId":"root","message":{"content":"inheritedqueuefixture"}}),
        ],
    );
    assert_eq!(scan(&f)["parseFailures"], 0);
    let db = f.store.reader().unwrap();
    let owner: String = db.query_row("SELECT src.local_path FROM session s JOIN source src USING(source_id) WHERE s.thread_id='claude_fork'", [], |row|row.get(0)).unwrap();
    assert_eq!(Path::new(&owner), path);
}

#[test]
fn sessions_claude_workflow_children_keep_the_session_ancestor() {
    let f = fixture();
    let path = f
        .claude
        .with_extension("")
        .join("subagents/workflows/workflow/agent-nested.jsonl");
    write(
        &path,
        &[json!({"type":"user","sessionId":"root","message":{"content":"workflowchildfixture"}})],
    );
    assert_eq!(scan(&f)["parseFailures"], 0);
    let db = f.store.reader().unwrap();
    let parent: String = db.query_row("SELECT p.thread_id FROM session c JOIN session p ON p.session_key=c.parent_session_key WHERE c.thread_id='claude:root:nested'", [], |row|row.get(0)).unwrap();
    assert_eq!(parent, "claude_root");
}

#[test]
fn sessions_claude_workflow_journals_are_not_transcripts() {
    let f = fixture();
    let path = f
        .claude
        .with_extension("")
        .join("subagents/workflows/workflow/journal.jsonl");
    write(&path, &[json!({"type":"started","agentId":"fixture"})]);
    assert_eq!(scan(&f)["parseFailures"], 0);
    assert!(!f.origins[1].is_transcript(&path));
    let count: i64 = f
        .store
        .reader()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM source WHERE local_path=?1",
            [path.to_string_lossy().as_ref()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn sessions_claude_tool_result_jsonl_stays_evidence() {
    let f = fixture();
    let path = f
        .claude
        .with_extension("")
        .join("tool-results/records.jsonl");
    write(
        &path,
        &[json!({"type":"user","sessionId":"root","message":{"content":"toolresultjsonlfixture"}})],
    );
    assert_eq!(scan(&f)["parseFailures"], 0);
    assert!(!f.origins[1].is_transcript(&path));
    let db = f.store.reader().unwrap();
    let count: i64 = db
        .query_row(
            "SELECT count(*) FROM source WHERE local_path=?1",
            [path.to_string_lossy().as_ref()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
    let evidence: i64 = db
        .query_row(
            "SELECT count(*) FROM dependency WHERE local_path=?1",
            [path.to_string_lossy().as_ref()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(evidence, 1);
}

#[test]
fn sessions_read_seeks_all_address_forms_and_rejects_ambiguous_ids() {
    let f = fixture();
    scan(&f);
    let canonical: String = f
        .store
        .reader()
        .unwrap()
        .query_row(
            "SELECT session_key FROM session WHERE thread_id='codex-root'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let read = |target: &str| {
        query::read(
            &f.store.reader().unwrap(),
            query::ReadRequest {
                target: target.into(),
                offset: 0,
                length: Some(4 << 20),
                dependency: None,
            },
        )
    };
    let expected = std::fs::read(&f.codex).unwrap();
    for address in [&canonical, "codex-root", "fixture:codex-root"] {
        let result = read(address).unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(result["base64"].as_str().unwrap())
            .unwrap();
        assert_eq!(bytes, expected);
    }
    assert!(
        read("absent-session")
            .unwrap_err()
            .to_string()
            .starts_with("not_found:")
    );
    let mut other = f.origins[0].clone();
    other.host = "other".into();
    ingest::scan(&f.store, &[other], &AtomicBool::new(false)).unwrap();
    assert!(
        read("codex-root")
            .unwrap_err()
            .to_string()
            .starts_with("usage: ambiguous")
    );
    assert!(read(&canonical).is_ok());
    assert!(read("fixture:codex-root").is_ok());
    assert!(read("other:codex-root").is_ok());
}

#[test]
fn sessions_claude_empty_transcripts_keep_path_headers_through_content_ingest() {
    let f = fixture();
    let path = f.claude.with_file_name("empty.jsonl");
    std::fs::write(&path, b"").unwrap();
    let mut db = f.store.writer().unwrap();
    ingest::header(&mut db, &f.origins[1], &path, &AtomicBool::new(false)).unwrap();
    drop(db);
    assert_eq!(scan(&f)["parseFailures"], 0);
    let headers = query::inventory(&f.store.reader().unwrap(), None, 1000).unwrap();
    let header = headers
        .sessions
        .iter()
        .find(|header| header.thread_id == "claude_empty")
        .unwrap();
    assert!(header.cwd.is_none());
    assert!(header.title.is_none());
    assert!(header.started_at.is_none());
    assert!(header.last_at.is_none());
    let turns: i64 = f
        .store
        .reader()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM turn WHERE session_key=?1",
            [&header.session_key],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(turns, 0);
}

#[test]
fn sessions_thread_suffix_seeks_unique_ambiguous_and_missing_keys() {
    let f = fixture();
    scan(&f);
    let db = f.store.reader().unwrap();
    let unique = query::match_thread_suffix(&db, "fixture", "codex-root").unwrap();
    assert_eq!(unique.len(), 1);
    assert_eq!(unique[0].thread_id, "codex-root");
    assert_eq!(
        query::match_thread_suffix(&db, "fixture", "root")
            .unwrap()
            .len(),
        2
    );
    assert!(
        query::match_thread_suffix(&db, "fixture", "absent")
            .unwrap()
            .is_empty()
    );
    assert!(
        query::match_thread_suffix(&db, "other-host", "root")
            .unwrap()
            .is_empty()
    );
    assert!(query::match_thread_suffix(&db, "fixture", "").is_err());
    let lower = b"toor";
    let upper = b"toos";
    let plan: Vec<String> = db
        .prepare(&format!("EXPLAIN QUERY PLAN {}", query::THREAD_SUFFIX_SQL))
        .unwrap()
        .query_map(rusqlite::params!["fixture", lower, upper], |row| row.get(3))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert!(plan.iter().any(
        |step| step.contains("SEARCH s USING INDEX session_thread_suffix")
            && step.contains("thread_id_reversed>?")
            && step.contains("thread_id_reversed<?")
    ));
}

#[test]
fn sessions_incremental_append_preserves_items_and_reconcile_verifies_the_chain() {
    let f = fixture();
    scan(&f);
    let old_key = search(&f.store, "codexmiddle")["hits"][0]["itemKey"]
        .as_str()
        .unwrap()
        .to_owned();
    let old_revision: i64 = f
        .store
        .reader()
        .unwrap()
        .query_row(
            "SELECT revision FROM item WHERE item_key=?1",
            [&old_key],
            |row| row.get(0),
        )
        .unwrap();
    for text in ["firstchainappend", "secondchainappend"] {
        writeln!(OpenOptions::new().append(true).open(&f.codex).unwrap(), "{}", json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":text}]}})).unwrap();
        let result = ingest::scan_scope(
            &f.store,
            &f.origins,
            ingest::Scope::Changed(std::slice::from_ref(&f.codex)),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["parseFailures"], 0);
    }
    let db = f.store.reader().unwrap();
    let current_revision: i64 = db
        .query_row(
            "SELECT revision FROM item WHERE item_key=?1",
            [&old_key],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(current_revision, old_revision);
    let (chain, revision, verified): (String,i64,i64) = db.query_row("SELECT prefix_hash,revision,json_extract(append_state,'$.verified_revision') FROM source WHERE local_path=?1", [f.codex.to_string_lossy().as_ref()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?))).unwrap();
    assert!(verified < revision);
    drop(db);
    assert_eq!(scan(&f)["ingested"], 0);
    let db = f.store.reader().unwrap();
    let (current_chain, current_revision, verified): (String,i64,i64) = db.query_row("SELECT prefix_hash,revision,json_extract(append_state,'$.verified_revision') FROM source WHERE local_path=?1", [f.codex.to_string_lossy().as_ref()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?))).unwrap();
    assert_eq!(chain, current_chain);
    assert_eq!(revision, current_revision);
    assert_eq!(verified, revision);
    drop(db);
    let fresh = Store::open(f._directory.path().join("rebuilt/catalog.sqlite3")).unwrap();
    ingest::scan(&fresh, &f.origins, &AtomicBool::new(false)).unwrap();
    let rebuilt_chain: String = fresh
        .reader()
        .unwrap()
        .query_row(
            "SELECT prefix_hash FROM source WHERE local_path=?1",
            [f.codex.to_string_lossy().as_ref()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(chain, rebuilt_chain);
}

#[test]
fn sessions_reconcile_repairs_a_growing_rewrite_that_preserves_both_windows() {
    use std::io::{Seek, SeekFrom};
    let f = fixture();
    scan(&f);
    let raw = std::fs::read(&f.codex).unwrap();
    let middle = raw
        .windows(b"codexmiddle".len())
        .position(|window| window == b"codexmiddle")
        .unwrap();
    assert!(middle > 64 << 10);
    assert!(raw.len() - middle > 64 << 10);
    let old_key = search(&f.store, "codexmiddle")["hits"][0]["itemKey"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut file = OpenOptions::new().write(true).open(&f.codex).unwrap();
    file.seek(SeekFrom::Start(middle as u64)).unwrap();
    file.write_all(b"rewritemid!").unwrap();
    drop(file);
    writeln!(OpenOptions::new().append(true).open(&f.codex).unwrap(),"{}",json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"afterhiddenrewrite"}]}})).unwrap();
    let result = ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(std::slice::from_ref(&f.codex)),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(result["parseFailures"], 0);
    assert_eq!(
        search(&f.store, "afterhiddenrewrite")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        search(&f.store, "codexmiddle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
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
    assert_eq!(scan(&f)["parseFailures"], 0);
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
}

#[test]
fn sessions_active_malformed_record_keeps_a_gap_and_indexes_following_appends() {
    let f = fixture();
    scan(&f);
    let append = |text: &str| {
        writeln!(OpenOptions::new().append(true).open(&f.codex).unwrap(),"{}",json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":text}]}})).unwrap();
    };
    let incremental = || {
        ingest::scan_scope(
            &f.store,
            &f.origins,
            ingest::Scope::Changed(std::slice::from_ref(&f.codex)),
            &AtomicBool::new(false),
        )
        .unwrap()
    };
    let gap_start = f.codex.metadata().unwrap().len();
    writeln!(
        OpenOptions::new().append(true).open(&f.codex).unwrap(),
        "{{malformed}}"
    )
    .unwrap();
    append("aftergapfirst");
    assert_eq!(incremental()["parseFailures"], 1);
    let first = search(&f.store, "aftergapfirst")["hits"][0]["itemKey"]
        .as_str()
        .unwrap()
        .to_owned();
    let revision = || {
        f.store
            .reader()
            .unwrap()
            .query_row(
                "SELECT revision FROM item WHERE item_key=?1",
                [&first],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
    };
    let before = revision();
    append("aftergapsecond");
    assert_eq!(incremental()["parseFailures"], 1);
    assert_eq!(revision(), before);
    assert_eq!(
        search(&f.store, "aftergapsecond")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let db = f.store.reader().unwrap();
    let (offset, failure, state): (i64, String, String) = db
        .query_row(
            "SELECT ingested_offset,failure,append_state FROM source WHERE local_path=?1",
            [f.codex.to_string_lossy().as_ref()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        u64::try_from(offset).unwrap(),
        f.codex.metadata().unwrap().len()
    );
    assert_eq!(failure, "record_gap");
    let state: Value = serde_json::from_str(&state).unwrap();
    assert_eq!(state["gap_records"], 1);
    assert_eq!(state["first_gap"][0], gap_start);
    let reason: String = db
        .query_row(
            "SELECT stale_reason FROM coverage WHERE origin_host='fixture'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(reason, "parse_failure");
    drop(db);
    assert_eq!(scan(&f)["ingested"], 0);
    assert_eq!(revision(), before);
}
