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

fn fixture_store(path: PathBuf) -> Result<Store> {
    let store = Store::open(
        path,
        super::storage::Capacity::Fixed {
            free_bytes: 1 << 40,
        },
    )?;
    super::index::open(&*store.writer()?)?;
    Ok(store)
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
    let store = fixture_store(root.join("state/catalog.sqlite3")).unwrap();
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
fn cap_status(store: &Store) -> PathBuf {
    store
        .path
        .parent()
        .unwrap()
        .with_file_name("disk-cap-status.json")
}
fn start_worker(store: &Store, origins: &[Origin]) -> super::worker::Worker {
    super::worker::Worker::start(
        store.clone(),
        origins.to_vec(),
        Vec::new(),
        cap_status(store),
    )
    .unwrap()
}
fn await_full_pass(store: &Store) {
    let status = cap_status(store);
    let started = std::time::Instant::now();
    while !status.exists() {
        assert!(started.elapsed() < std::time::Duration::from_secs(60));
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::fs::remove_file(&status).unwrap();
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
                    local: true,
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
                dependency: None,
                local: true,
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
fn sessions_feed_records_only_evidence_and_keeps_its_newest_rows() {
    let f = fixture();
    scan(&f);
    let db = f.store.reader().unwrap();
    let cursor = changes::cursor(&db).unwrap();
    drop(db);
    let reopened = fixture_store(f.store.path.clone()).unwrap();
    assert_eq!(
        changes::cursor(&reopened.reader().unwrap()).unwrap(),
        cursor
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
    let after: i64 = cursor.rsplit_once(':').unwrap().1.parse().unwrap();
    let evidence: Vec<String> = reopened
        .reader()
        .unwrap()
        .prepare("SELECT evidence_path FROM change WHERE seq>?1")
        .unwrap()
        .query_map([after], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert_eq!(evidence.len(), 1, "{evidence:?}");
    assert!(evidence[0].ends_with(f.codex.file_name().unwrap().to_str().unwrap()));
    let head = changes::cursor(&reopened.reader().unwrap()).unwrap();
    scan(&f);
    assert_eq!(changes::cursor(&reopened.reader().unwrap()).unwrap(), head);
    let writer = f.store.writer().unwrap();
    changes::prune(&writer, 1).unwrap();
    let rows = |db: &rusqlite::Connection| {
        db.query_row("SELECT count(*) FROM change", [], |r| r.get::<_, i64>(0))
            .unwrap()
    };
    assert_eq!(rows(&writer), 1);
    changes::window(&reopened.reader().unwrap(), Some(&cursor)).unwrap();
    changes::prune(&writer, 0).unwrap();
    assert_eq!(rows(&writer), 0);
    let error = changes::window(&reopened.reader().unwrap(), Some(&cursor)).unwrap_err();
    assert!(error.to_string().starts_with("cursor_expired:"));
    changes::window(&reopened.reader().unwrap(), Some(&head)).unwrap();
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
            local: true,
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
            local: true,
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
    let store = fixture_store(root.path().join("state/catalog.sqlite3")).unwrap();
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
    let mirrored = f.store.path.with_file_name("mirrored.jsonl");
    std::fs::write(&mirrored, b"kept").unwrap();
    f.store
        .writer()
        .unwrap()
        .execute_batch("CREATE TABLE padding(data BLOB); INSERT INTO padding VALUES(zeroblob(52428800)); PRAGMA user_version=5; PRAGMA wal_checkpoint(TRUNCATE);")
        .unwrap();
    let bytes = |store: &Store| {
        ["", "-wal"]
            .iter()
            .map(|suffix| {
                let mut path = store.path.clone().into_os_string();
                path.push(suffix);
                std::fs::metadata(path).map_or(0, |m| m.len())
            })
            .sum::<u64>()
    };
    assert!(bytes(&f.store) > 50 << 20);
    fixture_store(f.store.path.clone()).unwrap();
    assert!(bytes(&f.store) < 4 << 20, "{}", bytes(&f.store));
    let db = f.store.reader().unwrap();
    assert_eq!(
        db.pragma_query_value(None, "auto_vacuum", |r| r.get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM sqlite_schema WHERE name='padding'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    drop(db);
    assert_eq!(std::fs::read(&mirrored).unwrap(), b"kept");
    assert!(changes::window(&f.store.reader().unwrap(), Some(&cursor)).is_err());
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
    let worker = start_worker(&f.store, &f.origins);
    await_full_pass(&f.store);
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
    let next = fixture_store(f.store.path.clone()).unwrap();
    let worker = start_worker(&next, &f.origins);
    std::fs::write(f.codex.with_file_name("pending-identity.jsonl"), b"{").unwrap();
    ingest::refresh_inventory(&next).unwrap();
    let page = query::inventory(&next.reader().unwrap(), None, 1000).unwrap();
    assert!(!page.complete);
    assert!(
        page.warnings
            .iter()
            .any(|warning| warning.contains("pending-identity.jsonl"))
    );
    worker.stop().unwrap();
}

#[test]
fn sessions_inventory_reports_an_ingest_failure_instead_of_waiting_out_the_backoff() {
    use std::os::unix::fs::PermissionsExt;
    let f = fixture();
    scan(&f);
    let locked = f.origins[0].path().join("2026");
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    let worker = start_worker(&f.store, &f.origins);
    for _ in 0..3 {
        await_full_pass(&f.store);
    }
    let error = ingest::refresh_inventory(&f.store).unwrap_err();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
    worker.stop().unwrap();
    assert!(
        format!("{error:#}").contains("Permission denied"),
        "{error:#}"
    );
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
    let target = fixture_store(destination.path().join("state/catalog.sqlite3")).unwrap();
    let _worker = start_worker(&target, &[]);
    let peer = f.store.clone();
    let origins = f.origins.clone();
    let call: mirror::Call = Arc::new(move |method: &'static str, params: Value| {
        let peer = peer.clone();
        let origins = origins.clone();
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
                "sessions/mirror/changes" => {
                    mirror::delta(&peer, "fixture", &origins, serde_json::from_value(params)?)
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
            tokio_util::sync::CancellationToken::new(),
            Arc::default()
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
            tokio_util::sync::CancellationToken::new(),
            Arc::default()
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
        Arc::default(),
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
                cause: if host == "unreachable" {
                    crate::cluster::link::Failure::Transport
                } else {
                    crate::cluster::link::Failure::Local
                },
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
async fn sessions_cluster_search_keeps_unclassified_failures_unavailable() {
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
            .any(|c| c["hostId"] == "away" && c["state"] == "unavailable")
    );
}

#[test]
#[ignore]
fn sessions_measure_corpus() -> Result<()> {
    let manifest = std::env::var("RC_SESSIONS_MEASURE_ORIGINS")?;
    let origins: Vec<Origin> = serde_json::from_slice(&std::fs::read(manifest)?)?;
    let store = Store::open(
        PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?),
        super::storage::Capacity::Host,
    )?;
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
    let store = Store::open(
        PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?),
        super::storage::Capacity::Host,
    )?;
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
            local: true,
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
fn sessions_headroom_keeps_the_floor_and_the_remaining_wal_allowance() {
    let gib = 1u64 << 30;
    let headroom = super::storage::headroom;
    assert_eq!(headroom(0, 30 * gib, 0), 2 * gib);
    assert_eq!(headroom(0, 30 * gib, 8 * gib), 10 * gib);
    assert_eq!(headroom(0, 30 * gib, 12 * gib), 10 * gib);
    assert_eq!(headroom(0, 19 * gib, 0), 0);
    assert_eq!(headroom(52 * gib, 100 * gib, 0), 4 * gib);
    assert_eq!(headroom(64 * gib, 100 * gib, 8 * gib), 0);
}

#[test]
fn sessions_cap_status_reports_usage_and_unknown_accounting() {
    let f = fixture();
    scan(&f);
    let status = f
        .store
        .path
        .parent()
        .unwrap()
        .with_file_name("disk-cap-status.json");
    let storage = &f.store.storage;
    storage.publish_cap(&status).unwrap();
    let report: Value = serde_json::from_slice(&std::fs::read(&status).unwrap()).unwrap();
    let mut keys: Vec<_> = report.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(
        keys,
        [
            "cap_bytes",
            "observed_at",
            "owner",
            "reason",
            "unmet",
            "used_bytes",
            "version"
        ]
    );
    assert_eq!(report["version"], 1);
    assert_eq!(report["owner"], "remotecoder-sessions");
    assert_eq!(report["cap_bytes"], super::storage::CAP_BYTES);
    assert_eq!(report["used_bytes"], storage.usage().unwrap().used_bytes);
    assert!(report["unmet"].is_boolean());
    assert!(report["observed_at"].as_str().unwrap().ends_with('Z'));
    std::fs::write(f.store.path.with_file_name(".accounting.dirty"), b"1").unwrap();
    storage.publish_cap(&status).unwrap();
    let report: Value = serde_json::from_slice(&std::fs::read(&status).unwrap()).unwrap();
    assert!(report["used_bytes"].is_null() && report["unmet"].is_null());
}

#[test]
fn sessions_writers_never_close_the_catalog_as_its_last_connection() {
    let f = fixture();
    scan(&f);
    let mut wal = f.store.path.clone().into_os_string();
    wal.push("-wal");
    assert!(std::path::Path::new(&wal).exists());
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
    let store = Store::open(
        PathBuf::from(std::env::var("RC_SESSIONS_MEASURE_DB")?),
        super::storage::Capacity::Host,
    )?;
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
    let cursor = changes::cursor(&f.store.reader().unwrap()).unwrap();
    let after: i64 = cursor.rsplit_once(':').unwrap().1.parse().unwrap();
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
    let evidence: i64 = db
        .query_row(
            "SELECT count(*) FROM change WHERE seq>?1 AND evidence_path LIKE ?2",
            rusqlite::params![
                after,
                format!("%/{}", f.codex.file_name().unwrap().to_string_lossy())
            ],
            |r| r.get(0),
        )
        .unwrap();
    assert!(evidence > 0);
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
            "SELECT (SELECT count(*) FROM session), (SELECT count(*) FROM source), (SELECT count(*) FROM change)",
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
                local: true,
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
    let fresh = fixture_store(f._directory.path().join("rebuilt/catalog.sqlite3")).unwrap();
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

fn item_rows(store: &Store) -> (i64, i64, i64) {
    store
        .reader()
        .unwrap()
        .query_row("SELECT min(rowid),max(rowid),count(*) FROM item", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .unwrap()
}

fn source_stamp(store: &Store, path: &Path) -> (String, i64) {
    store
        .reader()
        .unwrap()
        .query_row(
            "SELECT file_identity,revision FROM source WHERE local_path=?1",
            [path.to_string_lossy().as_ref()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

#[test]
fn sessions_metadata_only_changes_keep_items_in_place() {
    use std::os::unix::fs::PermissionsExt;
    let f = fixture();
    scan(&f);
    let items = item_rows(&f.store);
    let (_, revision) = source_stamp(&f.store, &f.codex);
    std::fs::set_permissions(&f.codex, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::set_permissions(&f.codex, std::fs::Permissions::from_mode(0o644)).unwrap();
    ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(std::slice::from_ref(&f.codex)),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(item_rows(&f.store), items);
    assert_eq!(
        source_stamp(&f.store, &f.codex),
        (ingest::identity(&f.codex.metadata().unwrap()), revision)
    );
    f.store
        .writer()
        .unwrap()
        .execute(
            "UPDATE source SET file_identity='FileRevision { device: 1 }'",
            [],
        )
        .unwrap();
    assert_eq!(scan(&f)["ingested"], 0);
    assert_eq!(item_rows(&f.store), items);
    assert_eq!(source_stamp(&f.store, &f.codex).1, revision);
}

#[test]
fn sessions_companion_changes_refresh_evidence_without_rebuilding_items() {
    let f = fixture();
    scan(&f);
    let items = item_rows(&f.store);
    let (_, revision) = source_stamp(&f.store, &f.claude);
    let companion = f.claude.with_extension("").join("tool-results/later.txt");
    std::fs::write(&companion, "later companion").unwrap();
    let dependency = |store: &Store| -> i64 {
        store
            .reader()
            .unwrap()
            .query_row(
                "SELECT count(*) FROM dependency WHERE path=?1",
                [companion.to_string_lossy().as_ref()],
                |r| r.get(0),
            )
            .unwrap()
    };
    scan(&f);
    assert_eq!(dependency(&f.store), 1);
    std::fs::remove_file(&companion).unwrap();
    scan(&f);
    assert_eq!(dependency(&f.store), 0);
    assert_eq!(item_rows(&f.store), items);
    assert_eq!(source_stamp(&f.store, &f.claude).1, revision);
}

#[test]
fn sessions_verified_copy_replacing_a_source_appends_in_place() {
    let f = fixture();
    scan(&f);
    let (first, last, count) = item_rows(&f.store);
    let copy = f.codex.with_extension("copy");
    std::fs::copy(&f.codex, &copy).unwrap();
    writeln!(OpenOptions::new().append(true).open(&copy).unwrap(), "{}", json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"replacedcopyappend"}]}})).unwrap();
    std::fs::rename(&copy, &f.codex).unwrap();
    ingest::scan_scope(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(std::slice::from_ref(&f.codex)),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(item_rows(&f.store), (first, last + 1, count + 1));
    assert_eq!(scan(&f)["ingested"], 0);
    assert_eq!(item_rows(&f.store), (first, last + 1, count + 1));
    assert_eq!(
        search(&f.store, "replacedcopyappend")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn sessions_images_outside_the_provider_home_are_not_missing_evidence() {
    let f = fixture();
    writeln!(OpenOptions::new().append(true).open(&f.claude).unwrap(), "{}", json!({"type":"assistant","sessionId":"root","uuid":"outside-1","timestamp":"2026-10-27T10:00:04Z","message":{"content":[{"type":"tool_use","id":"tool-2","name":"Read","input":{"file_path":"/outside/photo.png"}}]}})).unwrap();
    scan(&f);
    let db = f.store.reader().unwrap();
    let (dependencies, references, reason): (i64, i64, Option<String>) = db
        .query_row(
            "SELECT (SELECT count(*) FROM dependency WHERE path='/outside/photo.png'),(SELECT count(*) FROM item WHERE source_ref LIKE '%/outside/photo.png%'),(SELECT stale_reason FROM coverage WHERE origin_host='fixture')",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!((dependencies, references, reason), (0, 1, None));
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
                dependency: None,
                local: true,
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

#[test]
fn sessions_mirror_pages_seek_before_stats_and_deduplicate_shared_evidence() {
    let directory = tempfile::tempdir().unwrap();
    let home = directory.path().join("codex");
    let root = home.join("sessions");
    std::fs::create_dir_all(&root).unwrap();
    let actual = root.join("actual.jsonl");
    std::fs::write(&actual, b"fixture\n").unwrap();
    let store = fixture_store(directory.path().join("state/catalog.sqlite3")).unwrap();
    {
        let mut db = store.writer().unwrap();
        let tx = db.transaction().unwrap();
        for index in 0..1001 {
            let path = root.join(if index < 500 {
                format!("a{index:04}.jsonl")
            } else {
                format!("z{:04}.jsonl", index - 500)
            });
            tx.execute("INSERT INTO source(origin_host,provider,provider_home,path,local_path,file_identity,size,mtime_ns,ingested_offset,revision,present,prefix_hash,parser_state) VALUES('fixture','codex',?1,?2,?3,'',0,0,0,0,1,'','{}')", rusqlite::params![home.to_string_lossy(),path.to_string_lossy(),if index<500 {"/dev/null/not-a-directory"}else{actual.to_str().unwrap()}]).unwrap();
        }
        for id in [1, 2] {
            tx.execute(
                "INSERT INTO dependency VALUES(?1,'fixture',?2,?3,'image',NULL,1)",
                rusqlite::params![
                    id,
                    root.join("zz-shared").to_string_lossy(),
                    actual.to_string_lossy()
                ],
            )
            .unwrap();
        }
        tx.execute(
            "INSERT INTO coverage(origin_host,mode,provider_roots) VALUES('fixture','local',?1)",
            [serde_json::to_string(&vec![&root]).unwrap()],
        )
        .unwrap();
        tx.commit().unwrap();
    }
    let first = mirror::list(
        &store,
        "fixture",
        Some(root.join("a0499.jsonl").to_string_lossy().into_owned()),
    )
    .unwrap();
    assert_eq!(first["files"].as_array().unwrap().len(), 500);
    let second = mirror::list(
        &store,
        "fixture",
        Some(first["cursor"].as_str().unwrap().into()),
    )
    .unwrap();
    assert_eq!(second["files"].as_array().unwrap().len(), 2);
    assert!(second["cursor"].is_null());
    assert_eq!(second["files"][1]["dependency"], true);
    let steps: Vec<String> = store
        .reader()
        .unwrap()
        .prepare(&format!("EXPLAIN QUERY PLAN {}", mirror::LIST_SQL))
        .unwrap()
        .query_map(["fixture", ""], |r| r.get(3))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert!(
        steps
            .iter()
            .any(|step| step.contains("source") && step.contains("origin_host=? AND path>?")),
        "{steps:?}"
    );
    assert!(
        steps
            .iter()
            .any(|step| step.contains("dependency_origin_path")
                && step.contains("origin_host=? AND path>?")),
        "{steps:?}"
    );
    assert!(
        !steps.iter().any(|step| step.contains("AUTOMATIC")),
        "{steps:?}"
    );
}

#[test]
fn sessions_mirror_refuses_unavailable_roots_even_on_an_empty_cursor_page() {
    let f = fixture();
    scan(&f);
    let root = f.origins[0].path();
    std::fs::rename(&root, root.with_file_name("unavailable")).unwrap();
    for cursor in [None, Some("zzzz".into())] {
        assert!(
            mirror::list(&f.store, "fixture", cursor)
                .unwrap_err()
                .to_string()
                .contains("mirror presence is unknown")
        );
    }
}

#[test]
fn sessions_rotation_retires_only_proven_missing_identity_owners() {
    let f = fixture();
    scan(&f);
    let replacement = f.codex.with_file_name("a-replacement.jsonl");
    std::fs::rename(&f.codex, &replacement).unwrap();
    let worker = start_worker(&f.store, &f.origins);
    await_full_pass(&f.store);
    ingest::refresh_inventory(&f.store).unwrap();
    let headers = query::inventory(&f.store.reader().unwrap(), None, 1000).unwrap();
    assert_eq!(
        headers
            .sessions
            .iter()
            .filter(|row| row.thread_id == "codex-root")
            .count(),
        1
    );
    worker.stop().unwrap();
    let outcome = ingest::scan(&f.store, &f.origins, &AtomicBool::new(false)).unwrap();
    assert_eq!(outcome["parseFailures"], 0);
    assert_eq!(
        search(&f.store, "codexmiddle")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let owner: String = f.store.reader().unwrap().query_row("SELECT src.local_path FROM session s JOIN source src USING(source_id) WHERE s.thread_id='codex-root'",[],|r|r.get(0)).unwrap();
    assert_eq!(
        std::fs::canonicalize(owner).unwrap(),
        std::fs::canonicalize(&replacement).unwrap()
    );
}

#[test]
fn sessions_sql_bounds_cumulative_blob_and_escaped_text_before_conversion() {
    let f = fixture();
    scan(&f);
    let db = f.store.reader().unwrap();
    for sql in [
        "SELECT zeroblob(3145728),zeroblob(3145728)",
        "SELECT replace(hex(zeroblob(1048576)),'0',char(1))",
    ] {
        let response = query::sql(&db, sql).unwrap();
        assert_eq!(response["truncated"], true);
        assert_eq!(response["rows"], json!([]));
        assert!(serde_json::to_vec(&response).unwrap().len() < super::PAGE_BYTES);
    }
    assert!(query::sql(&db, "SELECT zeroblob(9437184)").is_err());
    assert_eq!(query::sql(&db, "SELECT 42").unwrap()["rows"], json!([[42]]));
}

#[tokio::test]
async fn sessions_cluster_retries_failed_members_instead_of_exhausting_them() {
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let observed = calls.clone();
    let call: cluster::MemberCall = Arc::new(move |host, _, params| {
        let observed = observed.clone();
        async move {
            assert_eq!(host, "peer");
            assert!(params["cursor"].is_null());
            if observed.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 2 {
                return Err(crate::cluster::link::LinkError {
                    cause: crate::cluster::link::Failure::Transport,
                    class: crate::wire::cluster::ErrorClass::Unavailable,
                    transmitted: false,
                    message: "unreachable fixture".into(),
                }
                .into());
            }
            Ok(json!({"hits":[{"itemKey":"peer:item"}],"cursor":null}))
        }
        .boxed()
    });
    let first = cluster::search(
        "local",
        json!({"hits":[],"cursor":null}),
        vec!["peer".into()],
        query::Search {
            query: "needle".into(),
            ..Default::default()
        },
        call.clone(),
    )
    .await
    .unwrap();
    assert_eq!(first["coverage"][1]["state"], "unreachable");
    let second = cluster::search(
        "local",
        json!({"hits":[],"cursor":null}),
        vec![],
        query::Search {
            query: "needle".into(),
            cursor: Some(first["cursor"].as_str().unwrap().into()),
            ..Default::default()
        },
        call.clone(),
    )
    .await
    .unwrap();
    assert_eq!(second["coverage"][1]["state"], "unreachable");
    let third = cluster::search(
        "local",
        json!({"hits":[],"cursor":null}),
        vec!["peer".into()],
        query::Search {
            query: "needle".into(),
            cursor: Some(second["cursor"].as_str().unwrap().into()),
            ..Default::default()
        },
        call,
    )
    .await
    .unwrap();
    assert_eq!(third["hits"].as_array().unwrap().len(), 1);
    assert_eq!(third["coverage"][1]["state"], "ok");
    assert!(third["cursor"].is_null());
    assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 3);
}

#[test]
fn sessions_cluster_search_hits_route_exact_reads_to_their_origin() -> Result<()> {
    let fixture = fixture();
    ingest::scan(&fixture.store, &fixture.origins, &AtomicBool::new(false))?;
    let page = query::search(
        &fixture.store.reader()?,
        &query::Search {
            query: "codexmiddle".into(),
            ..Default::default()
        },
    )?;
    let request = query::ReadRequest {
        target: page["hits"][0]["itemKey"].as_str().unwrap().into(),
        offset: 0,
        length: Some(64),
        dependency: None,
        local: false,
    };
    let (host, forwarded) = cluster::forward_read("another-host", request.clone())?.unwrap();
    assert_eq!(host, "fixture");
    let forwarded: query::ReadRequest = serde_json::from_value(forwarded)?;
    assert!(forwarded.local);
    let bytes = query::read(&fixture.store.reader()?, forwarded.clone())?;
    assert_eq!(bytes["offset"], 0);
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(bytes["base64"].as_str().unwrap())?
            .len(),
        64
    );
    assert!(cluster::forward_read("fixture", request.clone())?.is_none());
    assert!(cluster::forward_read("another-host", forwarded)?.is_none());
    let mut local = request;
    local.local = true;
    assert!(cluster::forward_read("another-host", local)?.is_none());
    let error = anyhow::Error::new(crate::cluster::link::LinkError {
        cause: crate::cluster::link::Failure::Local,
        class: crate::wire::cluster::ErrorClass::Unavailable,
        transmitted: false,
        message: "origin offline".into(),
    });
    assert_eq!(super::error_data(&error)["class"], "unavailable");
    Ok(())
}

#[test]
fn sessions_search_uses_descending_fts_order_and_exact_dates() -> Result<()> {
    let fixture = fixture();
    ingest::scan(&fixture.store, &fixture.origins, &AtomicBool::new(false))?;
    let db = fixture.store.reader()?;
    let plan: Vec<String> = db
        .prepare(&format!("EXPLAIN QUERY PLAN {}", query::SEARCH_SQL))?
        .query_map(
            rusqlite::params!["\"agents\"", None::<String>, i64::MAX, "agents", 2],
            |row| row.get(3),
        )?
        .collect::<rusqlite::Result<_>>()?;
    assert!(
        plan.iter().any(|line| line.contains("VIRTUAL TABLE INDEX")),
        "{plan:?}"
    );
    assert!(
        !plan.iter().any(|line| line.contains("TEMP B-TREE")),
        "{plan:?}"
    );
    let mut samples = Vec::new();
    for (term, since) in [
        ("SKILL.md", None),
        ("Process exited", None),
        ("codex-threads", None),
        ("permission", None),
        ("Continue target", None),
        ("pair-programming", None),
        ("PID start time", None),
        ("remote-coder", None),
        ("agents", None),
        ("FileRevision", None),
        ("SKILL.md", Some("2026-10-15T00:00:00Z")),
    ] {
        let mut milliseconds = Vec::new();
        for _ in 0..5 {
            let started = Instant::now();
            query::search(
                &db,
                &query::Search {
                    query: term.into(),
                    since: since.map(str::to_owned),
                    ..Default::default()
                },
            )?;
            milliseconds.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        samples.push(json!({"term":term,"since":since,"sampleMs":milliseconds}));
    }
    println!("{}", json!({"searchFixtureSamples":samples,"plan":plan}));
    let mut request = query::Search {
        query: "SKILL.md".into(),
        limit: Some(1),
        ..Default::default()
    };
    let first = query::search(&db, &request)?;
    request.cursor = first["cursor"].as_str().map(str::to_owned);
    assert!(request.cursor.is_some());
    let next = query::search(&db, &request)?;
    assert_ne!(first["hits"][0]["itemKey"], next["hits"][0]["itemKey"]);
    request.cursor = None;
    request.since = Some("2999-01-01T00:00:00Z".into());
    assert!(
        query::search(&db, &request)?["hits"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    Ok(())
}

fn mirror_peer(
    f: &Fixture,
    calls: Arc<std::sync::Mutex<Vec<String>>>,
    fail: Arc<AtomicBool>,
) -> mirror::Call {
    let peer = f.store.clone();
    let origins = f.origins.clone();
    Arc::new(move |method, params| {
        let peer = peer.clone();
        let origins = origins.clone();
        let calls = calls.clone();
        let fail = fail.clone();
        async move {
            calls.lock().unwrap().push(method.to_owned());
            match method {
                "sessions/mirror/list" => mirror::list(
                    &peer,
                    "fixture",
                    params["cursor"].as_str().map(str::to_owned),
                ),
                "sessions/mirror/changes" => {
                    mirror::delta(&peer, "fixture", &origins, serde_json::from_value(params)?)
                }
                "sessions/mirror/fetch" => {
                    anyhow::ensure!(
                        !fail.load(std::sync::atomic::Ordering::Acquire),
                        "unavailable: injected transfer failure"
                    );
                    mirror::fetch(&peer, "fixture", serde_json::from_value(params)?)
                }
                _ => anyhow::bail!("Unexpected member method"),
            }
        }
        .boxed()
    })
}

async fn sync_mirror(target: &Store, call: mirror::Call) -> Result<Value> {
    mirror::sync(
        target,
        "fixture",
        call,
        tokio_util::sync::CancellationToken::new(),
        Arc::default(),
    )
    .await
}

fn mirror_cursor(target: &Store) -> String {
    target
        .reader()
        .unwrap()
        .query_row(
            "SELECT cursor FROM mirror_state WHERE origin_host='fixture'",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

#[tokio::test]
async fn sessions_mirror_idle_uses_only_feed_and_defers_full_tree_reconciliation() -> Result<()> {
    let f = fixture();
    scan(&f);
    let directory = tempfile::tempdir()?;
    let target = fixture_store(directory.path().join("state/catalog.sqlite3"))?;
    let _worker = start_worker(&target, &[]);
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    let call = mirror_peer(&f, calls.clone(), Arc::new(AtomicBool::new(false)));
    assert_eq!(sync_mirror(&target, call.clone()).await?["full"], true);
    calls.lock().unwrap().clear();
    let origin_reader = f.store.reader()?;
    let target_reader = target.reader()?;
    let before = target.path.metadata()?.modified()?;
    let orphan = directory
        .path()
        .join("state/mirror")
        .join(blake3::hash(b"fixture").to_hex().as_str())
        .join("orphan");
    std::fs::write(&orphan, b"orphan")?;
    let cursor = mirror_cursor(&target);
    let idle = sync_mirror(&target, call.clone()).await?;
    assert_eq!(idle["files"], 0);
    assert_eq!(idle["full"], false);
    assert_eq!(*calls.lock().unwrap(), vec!["sessions/mirror/changes"]);
    assert_eq!(mirror_cursor(&target), cursor);
    assert_eq!(target.path.metadata()?.modified()?, before);
    assert!(orphan.is_file());
    drop(target_reader);
    drop(origin_reader);
    target
        .writer()?
        .execute("UPDATE mirror_state SET reconciled_at=0", [])?;
    assert_eq!(sync_mirror(&target, call).await?["full"], true);
    assert!(!orphan.exists());
    let plan: Vec<String> = f
        .store
        .reader()?
        .prepare(&format!("EXPLAIN QUERY PLAN {}", mirror::DELTA_SQL))?
        .query_map(rusqlite::params!["fixture", 0], |r| r.get(3))?
        .collect::<rusqlite::Result<_>>()?;
    assert!(
        plan.iter()
            .any(|p| p.contains("USING INDEX change_evidence (origin_host=? AND seq>?)")),
        "{plan:?}"
    );
    assert!(!plan.iter().any(|p| p.contains("TEMP B-TREE")), "{plan:?}");
    Ok(())
}

#[tokio::test]
async fn sessions_mirror_skips_failed_transfers_until_full_reconciliation_and_preserves_unknown_roots()
-> Result<()> {
    let f = fixture();
    scan(&f);
    let directory = tempfile::tempdir()?;
    let target = fixture_store(directory.path().join("state/catalog.sqlite3"))?;
    let _worker = start_worker(&target, &[]);
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    let fail = Arc::new(AtomicBool::new(false));
    let call = mirror_peer(&f, calls.clone(), fail.clone());
    sync_mirror(&target, call.clone()).await?;
    let cursor = mirror_cursor(&target);
    let new = f.codex.with_file_name("delta-new.jsonl");
    write(
        &new,
        &[
            codex_meta("delta-new", None),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"deltauniquetext"}]}}),
        ],
    );
    scan(&f);
    fail.store(true, std::sync::atomic::Ordering::Release);
    let skipped = sync_mirror(&target, call.clone()).await?;
    assert_eq!(skipped["complete"], false);
    assert_ne!(mirror_cursor(&target), cursor);
    let cursor = mirror_cursor(&target);
    fail.store(false, std::sync::atomic::Ordering::Release);
    assert_eq!(sync_mirror(&target, call.clone()).await?["complete"], false);
    target
        .writer()?
        .execute("UPDATE mirror_state SET reconciled_at=0", [])?;
    let unavailable = f.origins[0].path().with_file_name("unavailable");
    std::fs::rename(f.origins[0].path(), &unavailable)?;
    assert!(
        sync_mirror(&target, call.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("presence is unknown")
    );
    assert_eq!(mirror_cursor(&target), cursor);
    assert_eq!(
        query::inventory(&target.reader()?, None, 1000)?
            .sessions
            .len(),
        4
    );
    std::fs::rename(&unavailable, f.origins[0].path())?;
    calls.lock().unwrap().clear();
    assert_eq!(sync_mirror(&target, call.clone()).await?["full"], true);
    assert_eq!(
        search(&target, "deltauniquetext")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    std::fs::remove_file(&new)?;
    scan(&f);
    sync_mirror(&target, call.clone()).await?;
    assert!(
        !query::inventory(&target.reader()?, None, 1000)?
            .sessions
            .iter()
            .any(|s| s.thread_id == "delta-new")
    );
    target
        .writer()?
        .execute("UPDATE mirror_state SET cursor='1:expired:0'", [])?;
    assert_eq!(sync_mirror(&target, call).await?["full"], true);
    Ok(())
}

#[tokio::test]
async fn sessions_mirror_replays_changes_that_race_the_initial_listing() -> Result<()> {
    let f = fixture();
    scan(&f);
    let directory = tempfile::tempdir()?;
    let target = fixture_store(directory.path().join("state/catalog.sqlite3"))?;
    let _worker = start_worker(&target, &[]);
    let peer = f.store.clone();
    let origins = f.origins.clone();
    let new = f.codex.with_file_name("racing.jsonl");
    let introduced = Arc::new(AtomicBool::new(false));
    let call: mirror::Call = Arc::new(move |method, params| {
        let peer = peer.clone();
        let origins = origins.clone();
        let new = new.clone();
        let introduced = introduced.clone();
        async move {
            match method {
                "sessions/mirror/list"=>{
                    let page=mirror::list(&peer,"fixture",params["cursor"].as_str().map(str::to_owned))?;
                    if !introduced.swap(true,std::sync::atomic::Ordering::AcqRel) {
                        write(&new,&[codex_meta("racing",None),json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"racinguniquetext"}]}})]);
                        ingest::scan(&peer,&origins,&AtomicBool::new(false))?;
                    }
                    Ok(page)
                }
                "sessions/mirror/changes"=>mirror::delta(&peer,"fixture",&origins,serde_json::from_value(params)?),
                "sessions/mirror/fetch"=>mirror::fetch(&peer,"fixture",serde_json::from_value(params)?),
                _=>anyhow::bail!("Unexpected method"),
            }
        }.boxed()
    });
    sync_mirror(&target, call.clone()).await?;
    sync_mirror(&target, call).await?;
    assert_eq!(
        search(&target, "racinguniquetext")["hits"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    Ok(())
}

#[test]
fn sessions_mirror_contains_paths_by_components() {
    let origin = Origin {
        host: "fixture".into(),
        provider: "codex".into(),
        provider_home: "/Users/emil/.codex".into(),
        local_home: "/mirror/codex".into(),
    };
    assert_eq!(
        origin
            .local(Path::new("///Users/emil/.codex/sessions/rollout.jsonl"))
            .unwrap(),
        PathBuf::from("/mirror/codex/sessions/rollout.jsonl")
    );
    assert!(
        origin
            .local(Path::new("/Users/emil/.codex/../secret"))
            .is_err()
    );
    assert!(
        origin
            .local(Path::new("/Users/emil/.openclaw/media/browser/image.jpg"))
            .is_err()
    );
}

#[tokio::test]
async fn sessions_mirror_skips_outside_entries_without_reclaiming() -> Result<()> {
    let f = fixture();
    scan(&f);
    let directory = tempfile::tempdir()?;
    let target = fixture_store(directory.path().join("state/catalog.sqlite3"))?;
    let _worker = start_worker(&target, &[]);
    let peer = mirror_peer(&f, Arc::default(), Arc::new(AtomicBool::new(false)));
    sync_mirror(&target, peer.clone()).await?;
    let orphan = target
        .path
        .parent()
        .unwrap()
        .join("mirror")
        .join(blake3::hash(b"fixture").to_hex().as_str())
        .join("retained");
    std::fs::write(&orphan, b"keep")?;
    target
        .writer()?
        .execute("UPDATE mirror_state SET reconciled_at=0", [])?;
    let call: mirror::Call = Arc::new(move |method, params| {
        let peer = peer.clone();
        async move {
            let mut page = peer(method, params).await?;
            if method == "sessions/mirror/list" {
                let entries = page["files"].as_array_mut().unwrap();
                let mut outside = entries[0].clone();
                outside["path"] = json!("/Users/emil/.openclaw/media/browser/image.jpg");
                entries.insert(0, outside);
                let path = entries[1]["path"].as_str().unwrap();
                entries[1]["path"] = json!(format!("//{path}"));
            }
            Ok(page)
        }
        .boxed()
    });
    let page = sync_mirror(&target, call).await?;
    assert_eq!(page["complete"], false);
    assert!(orphan.is_file());
    assert_eq!(
        query::inventory(&target.reader()?, None, 1000)?
            .sessions
            .len(),
        4
    );
    Ok(())
}

#[tokio::test]
async fn sessions_mirror_appends_verified_growth_and_replaces_a_changed_prefix() -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let f = fixture();
    scan(&f);
    let directory = tempfile::tempdir()?;
    let target = fixture_store(directory.path().join("state/catalog.sqlite3"))?;
    let _worker = start_worker(&target, &[]);
    let peer = mirror_peer(&f, Arc::default(), Arc::new(AtomicBool::new(false)));
    sync_mirror(&target, peer.clone()).await?;
    let path: String = target.reader()?.query_row(
        "SELECT local_path FROM mirror_file WHERE origin_host='fixture' AND path=?1",
        [f.codex.to_string_lossy()],
        |row| row.get(0),
    )?;
    let inode = std::fs::metadata(&path)?.ino();
    writeln!(
        OpenOptions::new().append(true).open(&f.codex)?,
        "{}",
        json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"appendedmirrorneedle"}]}})
    )?;
    scan(&f);
    sync_mirror(&target, peer.clone()).await?;
    assert_eq!(std::fs::metadata(&path)?.ino(), inode);
    assert_eq!(std::fs::read(&path)?, std::fs::read(&f.codex)?);
    let rewritten = std::fs::read_to_string(&f.codex)?.replace("codexmiddle", "rewrittenxx");
    std::fs::write(&f.codex, rewritten)?;
    scan(&f);
    sync_mirror(&target, peer).await?;
    assert_eq!(std::fs::read(&path)?, std::fs::read(&f.codex)?);
    Ok(())
}

#[test]
fn sessions_inventory_header_coverage_does_not_require_parsed_bodies() -> Result<()> {
    let f = fixture();
    scan(&f);
    f.store.writer()?.execute("UPDATE source SET failure='partial_record' WHERE source_id IN (SELECT source_id FROM session)",[])?;
    let db = f.store.reader()?;
    let page = query::inventory(&db, None, 1000)?;
    assert!(page.complete);
    assert!(page.warnings.is_empty());
    assert_eq!(
        query::match_thread_suffix(&db, "fixture", "codex-root")?.len(),
        1
    );
    Ok(())
}

fn conversation_search(
    store: &Store,
    query: &str,
    limit: usize,
    parents: std::collections::HashMap<String, Option<String>>,
) -> super::conversations::Response {
    {
        let db = store.writer().unwrap();
        for (key, parent) in parents {
            db.execute("UPDATE session SET delegated_parent_known=1,delegated_parent_session_key=?2 WHERE session_key=?1",rusqlite::params![key,parent]).unwrap();
        }
    }
    {
        let mut db = store.writer().unwrap();
        while super::index::rebuild_one(&mut db).unwrap() {}
    }
    let control = super::store::ReadControl::new(Instant::now() + super::conversations::DEADLINE);
    let mut db = store.reader().unwrap();
    db.interrupt_on(control.clone()).unwrap();
    super::conversations::search(
        &db,
        &super::conversations::Request {
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
    let root = super::session_key(&f.origins[0], "codex-root");
    let child = super::session_key(&f.origins[0], "codex-child");
    let other = super::session_key(&f.origins[1], "claude_root");
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
            .hits
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
            .any(|c| c.session_key == child && c.hits.iter().all(|h| h.agent_thread_id.is_none()))
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
        let key = |id| super::session_key(origin, id);
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
    let key = super::session_key(&f.origins[0], "codex-root");
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
    assert_eq!(result.conversations[0].hits[0].kind, "assistant");
    Ok(())
}

#[test]
fn sessions_conversations_bound_hits_and_exclude_folder_only_matches() {
    let f = fixture();
    scan(&f);
    let root = super::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer().unwrap();
        db.execute("DELETE FROM item", []).unwrap();
        db.execute("UPDATE session SET title=NULL,cwd='/needle'", [])
            .unwrap();
        for id in 0..=super::conversations::TERM_WINDOW {
            conversation_item(&db, &root, id, "needle", "assistant", None);
        }
    }
    let result = conversation_search(&f.store, "needle", 30, Default::default());
    assert!(result.truncated);
    assert_eq!(result.conversations.len(), 1);
    assert_eq!(
        result.conversations[0].hit_count,
        super::conversations::TERM_WINDOW
    );
    assert_eq!(result.conversations[0].hits.len(), 3);
    assert!(
        conversation_search(&f.store, "absent needle", 30, Default::default())
            .conversations
            .is_empty()
    );
}

#[test]
fn sessions_conversations_rebuild_indexes_from_rows_and_report_pending_work() {
    let f = fixture();
    scan(&f);
    let root = super::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer().unwrap();
        conversation_item(&db, &root, 999, "PreciseIdentifier", "assistant", None);
    }
    let request = super::conversations::Request {
        query: "PreciseIdentifier".into(),
        limit: 30,
    };
    let control = super::store::ReadControl::new(Instant::now() + super::conversations::DEADLINE);
    assert_eq!(
        conversation_search(&f.store, "PreciseIdentifier", 30, Default::default()).conversations[0]
            .session_key,
        root
    );
    {
        let db = f.store.writer().unwrap();
        db.execute("UPDATE meta SET value='old' WHERE key='search_version'", [])
            .unwrap();
        super::index::open(&db).unwrap();
    }
    assert!(
        super::conversations::search(
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
        super::storage::Capacity::Fixed {
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
    let request = super::conversations::Request {
        query: "fixture".into(),
        limit: 30,
    };
    let control = super::store::ReadControl::new(Instant::now() + super::conversations::DEADLINE);
    let response = super::conversations::search(&db, &request, &control, &Default::default())?;
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
    let root = super::session_key(&f.origins[0], "codex-root");
    let mut db = f.store.writer()?;
    db.execute(
        "UPDATE coverage SET stale_reason=NULL,complete_through='2026-11-01'",
        [],
    )?;
    db.execute("UPDATE meta SET value='1' WHERE key='catalog_ready'", [])?;
    db.execute("UPDATE search_document SET refreshed_ms=CAST(unixepoch('subsec')*1000 AS INTEGER),cooldown_ms=60000 WHERE session_key=?1", [&root])?;
    conversation_item(&db, &root, 1000, "DeferredIdentifier", "assistant", None);
    let stopped = AtomicBool::new(false);
    let next = super::index::drain(&mut db, &stopped, &mut |_| Ok(()))?;
    assert!(next.is_some_and(|next| next > Instant::now()));
    let query = |term: &str| {
        let request = super::conversations::Request {
            query: term.into(),
            limit: 30,
        };
        let control =
            super::store::ReadControl::new(Instant::now() + super::conversations::DEADLINE);
        super::conversations::search(&f.store.reader()?, &request, &control, &Default::default())
    };
    let pending = query("DeferredIdentifier")?;
    assert!(!pending.truncated);
    assert!(pending.conversations.is_empty());
    db.execute(
        "UPDATE search_document SET refreshed_ms=0 WHERE session_key=?1",
        [&root],
    )?;
    assert!(super::index::drain(&mut db, &stopped, &mut |_| Ok(()))?.is_none());
    assert_eq!(
        query("DeferredIdentifier")?.conversations[0].session_key,
        root
    );
    Ok(())
}

#[test]
fn sessions_conversations_cap_only_assistant_document_text() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = super::session_key(&f.origins[0], "codex-root");
    {
        let db = f.store.writer()?;
        let cap = super::index::ASSISTANT_BYTES as usize;
        conversation_item(
            &db,
            &root,
            1000,
            &format!("OldAssistantAnchor {}", "old ".repeat(40)),
            "assistant",
            None,
        );
        conversation_item(&db, &root, 1001, "TypedTailAnchor", "user", None);
        let newest = "NewestAssistantAnchor ";
        conversation_item(
            &db,
            &root,
            1002,
            &format!("{newest}{}", "cd ".repeat((cap - newest.len() - 16) / 3)),
            "assistant",
            None,
        );
    }
    let search = |query| conversation_search(&f.store, query, 1, Default::default());
    assert!(search("OldAssistantAnchor").conversations.is_empty());
    assert_eq!(search("TypedTailAnchor").conversations[0].session_key, root);
    assert_eq!(
        search("NewestAssistantAnchor").conversations[0].session_key,
        root
    );
    let db = f.store.reader()?;
    let status = super::query::sql(&db, "SELECT 1")?;
    assert_eq!(status["coverage"]["conversationSearch"]["cappedRoots"], 1);
    Ok(())
}

#[test]
fn sessions_conversations_timeout_preserves_completed_results() {
    let f = fixture();
    scan(&f);
    let control = super::store::ReadControl::new(Instant::now());
    let completed = Arc::new(std::sync::Mutex::new(Some(
        super::conversations::Response {
            schema_version: 1,
            truncated: false,
            conversations: vec![],
        },
    )));
    let result = super::conversations::search(
        &f.store.reader().unwrap(),
        &super::conversations::Request {
            query: "drawer".into(),
            limit: 30,
        },
        &control,
        &completed,
    )
    .unwrap();
    assert!(result.truncated);
}

#[test]
fn sessions_conversations_ignore_punctuation_only_query_terms() -> Result<()> {
    let f = fixture();
    scan(&f);
    let key = super::session_key(&f.origins[0], "codex-root");
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
        super::conversations::Request {
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
    use super::conversations::Request;
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
    let control =
        super::store::ReadControl::new(Instant::now() + std::time::Duration::from_secs(5));
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
    let root = super::session_key(&f.origins[0], "codex-root");
    let child = super::session_key(&f.origins[0], "codex-child");
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
fn sessions_conversations_preserve_origin_facts_through_replacement() -> Result<()> {
    let f = fixture();
    scan(&f);
    let root = super::session_key(&f.origins[0], "codex-root");
    let child = super::session_key(&f.origins[0], "codex-child");
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
        super::metadata::titles(&db, &f.origins)?;
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
    super::metadata::titles(&db, &f.origins)?;
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
    super::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "First title");
    let mut file = OpenOptions::new().append(true).open(&path)?;
    file.write_all(b"\xff\n")?;
    write!(
        file,
        "{{\"id\":\"codex-root\",\"thread_name\":\"Append title\""
    )?;
    super::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "First title");
    writeln!(file, "}}")?;
    super::metadata::titles(&db, &f.origins)?;
    assert_eq!(current()?, "Append title");
    write(
        &path,
        &[json!({"id":"codex-root","thread_name":"Replacement title"})],
    );
    super::metadata::titles(&db, &f.origins)?;
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
    let store = Store::open(path, super::storage::Capacity::Host)?;
    let started = Instant::now();
    let outcome = ingest::scan(&store, &origins, &AtomicBool::new(false))?;
    {
        let db = store.writer()?;
        super::metadata::titles(&db, &origins)?;
    }
    {
        let mut db = store.writer()?;
        while super::index::rebuild_one(&mut db)? {}
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
    let key = super::session_key(&f.origins[0], "codex-root");
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
    let excerpt = &result.conversations[0].hits[0].excerpt;
    assert!(excerpt.contains("Malmö"));
    assert!(excerpt.chars().count() <= 240);
}

#[test]
fn sessions_conversations_excerpt_finds_a_deep_prefix() {
    let f = fixture();
    scan(&f);
    let key = super::session_key(&f.origins[0], "codex-root");
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
    let excerpt = &result.conversations[0].hits[0].excerpt;
    assert!(excerpt.contains("DeepMalmöFlickering"));
    assert!(excerpt.chars().count() <= 240);
}

#[test]
fn sessions_conversations_count_matches_without_bounded_excerpts() -> Result<()> {
    let f = fixture();
    scan(&f);
    let key = super::session_key(&f.origins[0], "codex-root");
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
    assert!(result.truncated);
    assert_eq!(result.conversations.len(), 1);
    let conversation = &result.conversations[0];
    assert!(!conversation.title_match);
    assert_eq!(conversation.hit_count, 1);
    assert!(conversation.hits.is_empty());
    Ok(())
}

#[test]
fn sessions_locate_preserves_native_turn_and_checks_exact_source() -> Result<()> {
    let f = fixture();
    scan(&f);
    let db = f.store.reader()?;
    let key: String = db.query_row("SELECT item_key FROM item WHERE kind='tool_result' AND session_key LIKE '%codex-root' LIMIT 1", [], |r| r.get(0))?;
    let request = super::locate::Request { item_key: key };
    let control = super::store::ReadControl::new(Instant::now() + super::conversations::DEADLINE);
    let item = super::locate::item(&db, &request, &control)?;
    assert_eq!(item.response.thread_id, "codex-root");
    assert_eq!(item.response.turn_id.as_deref(), Some("turn-1"));
    assert!(item.response.item_id.is_none() && item.response.turns_cursor.is_none());
    std::fs::write(&f.codex, "changed source\n")?;
    assert!(
        super::locate::item(&db, &request, &control)
            .err()
            .unwrap()
            .to_string()
            .contains("source_changed")
    );
    assert!(
        serde_json::from_value::<super::locate::Request>(json!({"itemKey":"x","unknown":true}))
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
        {"sessionId":"unknown","provider":"claude","excerpt":"skip","score":9},
        {"sessionId":"codex-child","provider":"codex","excerpt":"child evidence","score":8},
        {"sessionId":"codex-root","provider":"codex","excerpt":"duplicate root","score":7},
        {"sessionId":"root","provider":"claude","excerpt":"Claude evidence","score":6}
    ]))?;
    let result = serde_json::to_value(super::meaning::resolve(&db, hits, 30)?)?;
    assert_eq!(result["conversations"].as_array().unwrap().len(), 2);
    assert_eq!(result["conversations"][0]["threadId"], "codex-root");
    assert_eq!(result["conversations"][0]["excerpt"], "child evidence");
    assert_eq!(result["conversations"][1]["threadId"], "claude_root");
    assert!(result["conversations"][1]["title"].is_null());
    Ok(())
}

#[test]
fn sessions_ingest_resumes_a_committed_inventory_checkpoint() -> Result<()> {
    let f = fixture();
    write(
        &f.codex,
        &[
            codex_meta("codex-root", None),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"before checkpoint"}}),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"after checkpoint"}}),
        ],
    );
    let stop = AtomicBool::new(false);
    let boundaries = std::cell::Cell::new(0);
    let mut accepted_revision = None;
    ingest::scan_serving(
        &f.store,
        &f.origins,
        ingest::Scope::Changed(std::slice::from_ref(&f.codex)),
        &stop,
        &|| {
            boundaries.set(boundaries.get() + 1);
            boundaries.get() == 3
        },
        &mut |db| {
            accepted_revision = Some(db.query_row(
                "SELECT revision FROM item WHERE text='before checkpoint'",
                [],
                |r| r.get::<_, i64>(0),
            )?);
            let future: i64 = db.query_row(
                "SELECT count(*) FROM item WHERE text='after checkpoint'",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(future, 0);
            stop.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        },
    )?;
    let accepted_revision = accepted_revision.expect("inventory checkpoint was committed");
    scan(&f);
    let db = f.store.reader()?;
    let (first, second): (i64, i64) = db.query_row(
        "SELECT (SELECT revision FROM item WHERE text='before checkpoint'),(SELECT revision FROM item WHERE text='after checkpoint')",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    assert_eq!(first, accepted_revision);
    assert!(second > first);
    Ok(())
}
