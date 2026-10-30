use super::*;

const ACCOUNT: &str = "11111111-1111-1111-1111-111111111111";
const THREAD: &str = "01a14ab7-fffc-7211-adac-4a0e73963e19";

struct Fixture {
    home: tempfile::TempDir,
    source: PathBuf,
    target: PathBuf,
    claude_home: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let home = tempfile::Builder::new()
            .prefix("codex-adoption-")
            .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
            .unwrap();
        let source = home.path().join(".rca").join(ACCOUNT.replace('-', ""));
        let target = home.path().join(".codex");
        let claude_home = home.path().join("configured-claude");
        std::fs::create_dir_all(source.join("c")).unwrap();
        std::fs::create_dir_all(&target).unwrap();
        Self {
            home,
            source,
            target,
            claude_home,
        }
    }

    fn state(&self, incoming: bool, name: &str, value: &Value) -> PathBuf {
        let directory = if incoming {
            self.source.join("state")
        } else {
            self.home.path().join(".remote-coder")
        };
        let path = directory.join(name);
        let root = Root::open(self.home.path()).unwrap();
        root.write_json(&path, value).unwrap();
        path
    }

    fn plan(&self) -> Result<Vec<StateWrite>> {
        plan_state(
            &Root::open(self.home.path())?,
            self.home.path(),
            &self.source,
            ACCOUNT,
            &[THREAD.into()],
            &[],
            &self.claude_home,
        )
    }

    fn native(&self) -> Value {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("test-fixtures/codex-adoption");
        let manifest: Value =
            serde_json::from_slice(&std::fs::read(fixture.join("manifest.json")).unwrap()).unwrap();
        let status = Command::new("tar")
            .arg("-xzf")
            .arg(fixture.join("native-home.tar.gz"))
            .arg("-C")
            .arg(&self.source)
            .status()
            .unwrap();
        assert!(status.success());
        python(
            r#"
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE threads SET rollout_path=replace(rollout_path,?,?)', (sys.argv[2],sys.argv[3]))
print('{}')
"#,
            &[
                self.source.join("c/state_5.sqlite"),
                PathBuf::from(manifest["originalHome"].as_str().unwrap()),
                self.source.join("c"),
            ],
        );
        manifest
    }
}

fn python(script: &str, arguments: &[PathBuf]) -> Value {
    let output = Command::new("python3")
        .args(["-I", "-c", script])
        .args(arguments)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn metadata(model: &str, updated: u64, revision: u64) -> Value {
    json!({"sessionID":THREAD,"modelID":model,"reasoningSelectionID":"medium","fastModeEnabled":false,"source":"runtime","updatedAt":updated,"serverRevision":revision,"mutationId":null})
}

fn question(item: &str, epoch: &str, revision: u64) -> Value {
    json!({
        "schemaVersion":1,"threadId":THREAD,"epoch":epoch,"revision":revision,"writer":"retired-process",
        "facts":{"definitions":{(item):{"itemId":item,"turnId":"turn","ordinal":1,"askedAtMs":1,"questions":[{"title":"Choose","options":[]}]}},"answers":{},"plainBoundary":null},
        "anchor":null,"incomplete":{},
        "scan":{"cursor":"old-cursor","initialCursor":null,"floor":null,"floorFound":false,"minimumOrdinal":null,"complete":false,"lineageChanged":false,"facts":{"definitions":{},"answers":{},"plainBoundary":null},"anchor":null,"incomplete":{}},
        "dismissals":{},"alerted":[item],"recordRevisions":{(item):revision}
    })
}

fn planned<'a>(writes: &'a [StateWrite], name: &str) -> &'a Value {
    &writes
        .iter()
        .find(|write| write.path.ends_with(name))
        .unwrap()
        .value
}

fn ledger() -> Value {
    serde_json::to_value(crate::gateway::DurableTurnState::default()).unwrap()
}

fn pending_start(thread: &str) -> Value {
    json!({"thread_id":thread,"context":{"preview":"Pending prompt","cwd":null,"owner_client_id":1},"previous_turn_id":null,"created_at_unix_seconds":1.0})
}

fn active_turn(turn: &str) -> Value {
    json!({"thread_id":THREAD,"turn_id":turn,"owner_client_id":1,"started_at_unix_seconds":1.0,"last_seen_at_unix_seconds":1.0})
}

#[test]
fn metadata_merge_selects_newest_values_and_advances_past_both_client_revisions() {
    let fixture = Fixture::new();
    let mut host_only = metadata("untouched", 5, 8);
    host_only["sessionID"] = "host-only".into();
    let original = fixture.state(false, "session-metadata-v2.json", &json!({"schemaVersion":1,"records":{(THREAD):metadata("host",10,40),"host-only":host_only}}));
    let source = fixture.state(
        true,
        "session-metadata-v2.json",
        &json!({"schemaVersion":1,"records":{(THREAD):metadata("enrollment",20,3)}}),
    );
    let original_bytes = std::fs::read(&original).unwrap();
    let source_bytes = std::fs::read(&source).unwrap();
    let writes = fixture.plan().unwrap();
    let records = &planned(&writes, "session-metadata-v2.json")["records"];
    assert_eq!(records[THREAD]["modelID"], "enrollment");
    assert_eq!(records[THREAD]["serverRevision"], 41);
    assert_eq!(records["host-only"]["modelID"], "untouched");
    assert_eq!(std::fs::read(original).unwrap(), original_bytes);
    assert_eq!(std::fs::read(source).unwrap(), source_bytes);
}

#[test]
fn question_adoption_resets_runtime_lineage_with_or_without_an_existing_host_record() {
    for existing in [false, true] {
        let fixture = Fixture::new();
        let incoming = question("source-item", "source-epoch", 4);
        let source = fixture.state(true, "questions/thread.json", &incoming);
        if existing {
            fixture.state(
                false,
                "questions/thread.json",
                &question("host-item", "host-epoch", 10),
            );
        }
        let writes = fixture.plan().unwrap();
        let merged = planned(&writes, "questions/thread.json");
        assert!(merged["writer"].is_null());
        assert!(merged["scan"].is_null());
        assert_ne!(merged["epoch"], "source-epoch");
        assert_ne!(merged["epoch"], "host-epoch");
        assert!(merged["revision"].as_u64().unwrap() > if existing { 10 } else { 4 });
        assert!(merged["facts"]["definitions"]["source-item"].is_object());
        assert_eq!(merged["recordRevisions"]["source-item"], merged["revision"]);
        if existing {
            assert!(merged["facts"]["definitions"]["host-item"].is_object());
            assert_eq!(merged["recordRevisions"]["host-item"], merged["revision"]);
        }
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(source).unwrap()).unwrap(),
            incoming
        );
    }
}

#[test]
fn active_and_queued_ledger_collisions_fail_before_replacing_either_owner() {
    for field in ["active_turns_by_key", "queued_submissions"] {
        let fixture = Fixture::new();
        let old = json!({(field):{"same-thread":{"turn":"host"}}});
        let incoming = json!({(field):{"same-thread":{"turn":"source"}}});
        let host = fixture.state(false, "active-codex-turns.json", &old);
        let source = fixture.state(true, "active-codex-turns.json", &incoming);
        let error = fixture.plan().err().unwrap().to_string();
        assert!(error.contains(&format!("{field}/same-thread")), "{error}");
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(host).unwrap()).unwrap(),
            old
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(source).unwrap()).unwrap(),
            incoming
        );
    }
}

#[test]
fn pending_start_request_ids_from_different_runtimes_remain_independent() {
    let fixture = Fixture::new();
    let mut host = ledger();
    host["pending_turn_starts"]["1"] = pending_start("host");
    fixture.state(false, "active-codex-turns.json", &host);
    let mut source = ledger();
    source["pending_turn_starts"]["1"] = pending_start("source");
    fixture.state(true, "active-codex-turns.json", &source);
    let writes = fixture.plan().unwrap();
    let starts = &planned(&writes, "active-codex-turns.json")["pending_turn_starts"];
    assert_eq!(starts["1"]["thread_id"], "host");
    assert_eq!(starts[format!("{ACCOUNT}:1")]["thread_id"], "source");
    assert_eq!(starts.as_object().unwrap().len(), 2);
}

#[test]
fn merged_turn_ledger_refuses_over_capacity_without_changing_either_owner() {
    for (field, capacity, value) in [
        (
            "queued_submissions",
            crate::turns::MAX_QUEUED_THREADS,
            json!({"held":true,"submissions":[]}),
        ),
        ("pending_native_mutations", 1024, json!(42)),
    ] {
        let fixture = Fixture::new();
        let mut host = ledger();
        for index in 0..capacity {
            host[field][format!("thread-{index}")] = value.clone();
        }
        let mut incoming = ledger();
        incoming[field]["source-thread"] = value;
        for document in [&host, &incoming] {
            serde_json::from_value::<crate::gateway::DurableTurnState>(document.clone())
                .unwrap()
                .validate()
                .unwrap();
        }
        let destination = fixture.state(false, "active-codex-turns.json", &host);
        let source = fixture.state(true, "active-codex-turns.json", &incoming);
        let host_bytes = std::fs::read(&destination).unwrap();
        let source_bytes = std::fs::read(&source).unwrap();
        let error = fixture.plan().err().unwrap().to_string();
        assert!(
            error.contains("Invalid merged active turn state"),
            "{field}: {error}"
        );
        assert_eq!(std::fs::read(destination).unwrap(), host_bytes);
        assert_eq!(std::fs::read(source).unwrap(), source_bytes);
        assert!(
            !fixture
                .home
                .path()
                .join(".remote-coder")
                .join(RECEIPT)
                .exists()
        );
    }
}

#[test]
fn replayed_turn_ledger_is_validated_before_any_planned_write() {
    for (field, capacity, value) in [
        (
            "queued_submissions",
            crate::turns::MAX_QUEUED_THREADS,
            json!({"held":true,"submissions":[]}),
        ),
        ("pending_native_mutations", 1024, json!(42)),
    ] {
        let fixture = Fixture::new();
        let root = Root::open(fixture.home.path()).unwrap();
        let destination = fixture.state(false, "active-codex-turns.json", &ledger());
        let metadata = fixture.state(false, "session-metadata-v2.json", &json!({"original":true}));
        let mut oversized = ledger();
        for index in 0..=capacity {
            oversized[field][format!("thread-{index}")] = value.clone();
        }
        let receipt = Receipt {
            profiles: BTreeMap::from([(
                ACCOUNT.into(),
                Adoption {
                    imported: true,
                    writes: Some(vec![
                        StateWrite {
                            path: metadata.clone(),
                            value: json!({"replaced":true}),
                        },
                        StateWrite {
                            path: destination.clone(),
                            value: oversized,
                        },
                    ]),
                    ..Adoption::default()
                },
            )]),
            ..Receipt::default()
        };
        root.write_json(
            &fixture.home.path().join(".remote-coder").join(RECEIPT),
            &receipt,
        )
        .unwrap();
        let host_bytes = std::fs::read(&destination).unwrap();
        let metadata_bytes = std::fs::read(&metadata).unwrap();
        let error = run(fixture.home.path(), &fixture.target, &fixture.claude_home)
            .err()
            .unwrap()
            .to_string();
        assert!(
            error.contains("Invalid merged active turn state"),
            "{error}"
        );
        assert_eq!(std::fs::read(destination).unwrap(), host_bytes);
        assert_eq!(std::fs::read(metadata).unwrap(), metadata_bytes);
    }
}

#[test]
fn merging_marks_preserves_each_profiles_read_baseline_and_explicit_unread_state() {
    let source = json!({"schemaVersion":3,"revision":5,"readBaseline":200,"threads":{"source-unread":{"revision":5,"markedUnread":true}}});
    let host = json!({"schemaVersion":3,"revision":7,"readBaseline":100,"threads":{"host":{"revision":7,"pinName":"Keep"}}});
    let merged = merge_marks(
        Some(host),
        source,
        &["source-unread".into(), "source-implicit".into()],
        &["host".into()],
    )
    .unwrap();
    assert_eq!(merged["readBaseline"], 100);
    assert_eq!(merged["threads"]["source-implicit"]["seenThrough"], 200);
    assert_eq!(merged["threads"]["source-unread"]["seenThrough"], 200);
    assert_eq!(merged["threads"]["source-unread"]["markedUnread"], true);
    assert_eq!(merged["threads"]["host"]["pinName"], "Keep");

    let source = json!({"schemaVersion":3,"revision":5,"readBaseline":100,"threads":{}});
    let host = json!({"schemaVersion":3,"revision":7,"readBaseline":200,"threads":{"host":{"revision":7,"pinName":"Keep"}}});
    let merged = merge_marks(
        Some(host),
        source,
        &["source-implicit".into()],
        &["host".into(), "host-implicit".into()],
    )
    .unwrap();
    assert_eq!(merged["readBaseline"], 100);
    assert_eq!(merged["threads"]["host"]["seenThrough"], 200);
    assert_eq!(merged["threads"]["host-implicit"]["seenThrough"], 200);
    assert_eq!(merged["threads"]["host"]["pinName"], "Keep");
}

#[test]
fn adopting_a_lower_marks_baseline_preserves_implicit_claude_reads_once() {
    let fixture = Fixture::new();
    let thread = crate::providers::claude::claude_thread_id(THREAD);
    let transcript = fixture
        .claude_home
        .join("projects/repo")
        .join(format!("{THREAD}.jsonl"));
    let contents = [
        json!({"type":"user","uuid":"prompt","timestamp":"1970-01-01T00:02:00Z","cwd":fixture.home.path(),"message":{"role":"user","content":"Existing conversation"}}),
        json!({"type":"assistant","uuid":"reply","timestamp":"1970-01-01T00:02:30Z","message":{"role":"assistant","content":[{"type":"text","text":"Finished"}],"stop_reason":"end_turn"}}),
    ]
    .iter()
    .map(|record| format!("{record}\n"))
    .collect::<String>();
    Root::open(fixture.home.path())
        .unwrap()
        .replace(&transcript, contents.as_bytes())
        .unwrap();
    let host = fixture.state(
        false,
        "conversation-marks.v3.json",
        &json!({"schemaVersion":3,"revision":7,"readBaseline":200,"threads":{}}),
    );
    let source = fixture.state(
        true,
        "conversation-marks.v3.json",
        &json!({"schemaVersion":3,"revision":5,"readBaseline":100,"threads":{}}),
    );
    let source_before = std::fs::read(&source).unwrap();
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    let persisted = std::fs::read(&host).unwrap();
    let marks: Value = serde_json::from_slice(&persisted).unwrap();
    assert_eq!(marks["readBaseline"], 100);
    assert_eq!(marks["threads"][&thread]["seenThrough"], 200);
    assert_eq!(std::fs::read(&transcript).unwrap(), contents.as_bytes());
    assert_eq!(std::fs::read(&source).unwrap(), source_before);
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    assert_eq!(std::fs::read(&host).unwrap(), persisted);
}

fn native_summary(home: &Path) -> Value {
    python(
        r#"
import json,pathlib,sqlite3,sys
home=pathlib.Path(sys.argv[1])
with sqlite3.connect(f'file:{home}/state_5.sqlite?mode=ro',uri=True) as db:
    threads=db.execute('SELECT id,archived,title FROM threads ORDER BY id').fetchall()
    edges=db.execute('SELECT parent_thread_id,child_thread_id,status FROM thread_spawn_edges ORDER BY parent_thread_id,child_thread_id').fetchall()
    receipts=db.execute('SELECT thread_id,first_unread_turn,revision,last_published_turn FROM thread_read_receipts ORDER BY thread_id').fetchall()
    guardian=db.execute('SELECT id,thread_id,hex(record) FROM guardian_review_feedback ORDER BY id').fetchall()
with sqlite3.connect(f'file:{home}/thread_history_1.sqlite?mode=ro',uri=True) as db:
    turns=dict(db.execute('SELECT thread_id,COUNT(*) FROM thread_turns GROUP BY thread_id'))
    items=dict(db.execute('SELECT thread_id,COUNT(*) FROM thread_items GROUP BY thread_id'))
with sqlite3.connect(f'file:{home}/queue_1.sqlite?mode=ro',uri=True) as db:
    queue=db.execute('SELECT COUNT(*) FROM queued_items').fetchone()[0]
print(json.dumps({'threads':threads,'edges':edges,'receipts':receipts,'guardian':guardian,'turns':turns,'items':items,'queue':queue}))
"#,
        &[home.to_owned()],
    )
}

fn source_bytes(source: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let root = Root::open(source).unwrap();
    let mut all = Vec::new();
    files(&root, source, &mut all).unwrap();
    all.into_iter()
        .filter(|path| {
            path.extension().is_some_and(|extension| {
                extension == "sqlite"
                    || extension == "jsonl"
                    || extension == "json"
                    || extension == "md"
            })
        })
        .map(|path| {
            (
                path.strip_prefix(source).unwrap().to_owned(),
                std::fs::read(path).unwrap(),
            )
        })
        .collect()
}

#[test]
fn real_native_history_and_gateway_state_resume_after_collision_without_repeating_writes() {
    let fixture = Fixture::new();
    let manifest = fixture.native();
    let source = fixture.source.join("c");
    python(
        "import sqlite3,sys\nwith sqlite3.connect(sys.argv[1]) as db: db.execute('INSERT INTO guardian_review_feedback VALUES(?,?,?)', ('01a14ab9-0000-7000-8000-000000000001',sys.argv[2],b'{\"decision\":\"approve\"}'))\nprint('{}')",
        &[source.join("state_5.sqlite"), THREAD.into()],
    );
    let baseline = native_summary(&source);
    assert_eq!(baseline["receipts"].as_array().unwrap().len(), 2);
    assert_eq!(baseline["guardian"].as_array().unwrap().len(), 1);
    for thread in manifest["threads"].as_array().unwrap() {
        let id = thread["id"].as_str().unwrap();
        assert_eq!(baseline["turns"][id], thread["projectionTurns"]);
        assert_eq!(baseline["items"][id], thread["projectionItems"]);
    }
    let canonical = fixture.state(
        false,
        "session-metadata-v2.json",
        &json!({"schemaVersion":1,"records":{(THREAD):metadata("host",10,40)}}),
    );
    fixture.state(
        true,
        "session-metadata-v2.json",
        &json!({"schemaVersion":1,"records":{(THREAD):metadata("enrollment",20,3)}}),
    );
    let mut host_ledger = ledger();
    host_ledger["active_turns_by_key"]["thread"] = active_turn("host");
    fixture.state(false, "active-codex-turns.json", &host_ledger);
    let mut source_ledger = ledger();
    source_ledger["active_turns_by_key"]["thread"] = active_turn("source");
    fixture.state(true, "active-codex-turns.json", &source_ledger);
    let original_source = source_bytes(&fixture.source);
    let metadata_before = std::fs::read(&canonical).unwrap();
    assert!(run(fixture.home.path(), &fixture.target, &fixture.claude_home).is_err());
    assert!(!is_settled(fixture.home.path()).unwrap());
    assert!(receipt(fixture.home.path()).unwrap().profiles[ACCOUNT].imported);
    assert_eq!(std::fs::read(&canonical).unwrap(), metadata_before);
    assert_eq!(native_summary(&fixture.target), baseline);
    fixture.state(false, "active-codex-turns.json", &ledger());
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    assert!(is_settled(fixture.home.path()).unwrap());
    assert_eq!(native_summary(&fixture.target), baseline);
    assert_eq!(source_bytes(&fixture.source), original_source);
    let metadata_after = std::fs::read(&canonical).unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&metadata_after).unwrap()["records"][THREAD]["serverRevision"],
        41
    );
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    assert_eq!(std::fs::read(canonical).unwrap(), metadata_after);
    assert_eq!(native_summary(&fixture.target), baseline);
    assert_eq!(source_bytes(&fixture.source), original_source);
}

#[test]
fn overlapping_native_threads_preserve_the_prior_database_family_on_resume() {
    let fixture = Fixture::new();
    fixture.native();
    let source = fixture.source.join("c");
    let root = Root::open(fixture.home.path()).unwrap();
    for database in DATABASES {
        let path = source.join(database);
        if path.exists() {
            root.clone_from(&root, &path, &fixture.target.join(database))
                .unwrap();
        }
    }
    python(
        "import sqlite3,sys\nwith sqlite3.connect(sys.argv[1]) as db: db.execute('INSERT INTO guardian_review_feedback VALUES(?,?,?)', ('01a14ab9-0000-7000-8000-000000000001',sys.argv[2],b'{\"decision\":\"approve\"}'))\nprint('{}')",
        &[source.join("state_5.sqlite"), THREAD.into()],
    );
    python(
        r#"
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE threads SET title=? WHERE id=?', ('Prior host title',sys.argv[2]))
    db.execute('UPDATE thread_read_receipts SET first_unread_turn=NULL,revision=? WHERE thread_id=?', ('prior-revision',sys.argv[2]))
    db.execute('INSERT INTO guardian_review_feedback VALUES(?,?,?)', ('01a14ab9-0000-7000-8000-000000000002',sys.argv[2],b'{"decision":"deny"}'))
print('{}')
"#,
        &[fixture.target.join("state_5.sqlite"), THREAD.into()],
    );
    let originals = DATABASES
        .into_iter()
        .filter_map(|name| {
            std::fs::read(fixture.target.join(name))
                .ok()
                .map(|bytes| (name, bytes))
        })
        .collect::<BTreeMap<_, _>>();
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    assert_eq!(native_summary(&fixture.target), native_summary(&source));
    let conflicts = fixture
        .home
        .path()
        .join(".remote-coder/codex-profile-conflicts")
        .join(ACCOUNT);
    for (name, bytes) in &originals {
        assert_eq!(&std::fs::read(conflicts.join(name)).unwrap(), bytes);
    }
    let restored = python(
        r#"
import json,sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    print(json.dumps({
        'title':db.execute('SELECT title FROM threads WHERE id=?',(sys.argv[2],)).fetchone()[0],
        'receipt':db.execute('SELECT first_unread_turn,revision FROM thread_read_receipts WHERE thread_id=?',(sys.argv[2],)).fetchone(),
        'guardian':db.execute('SELECT id FROM guardian_review_feedback WHERE thread_id=?',(sys.argv[2],)).fetchall(),
    }))
"#,
        &[conflicts.join("state_5.sqlite"), THREAD.into()],
    );
    assert_eq!(
        restored,
        json!({
            "title":"Prior host title",
            "receipt":[null,"prior-revision"],
            "guardian":[["01a14ab9-0000-7000-8000-000000000002"]],
        })
    );
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    for (name, bytes) in &originals {
        assert_eq!(&std::fs::read(conflicts.join(name)).unwrap(), bytes);
    }
}

#[test]
fn native_memories_and_goals_preserve_both_profiles_with_rollback_and_idempotency() {
    for (directory, name) in [
        ("memories", "memories_1.sqlite"),
        ("memories_v2", "memories_v2_1.sqlite"),
    ] {
        let fixture = Fixture::new();
        fixture.native();
        let root = Root::open(fixture.home.path()).unwrap();
        let source = fixture.source.join("c");
        if name != "memories_1.sqlite" {
            root.clone_from(&root, &source.join("memories_1.sqlite"), &source.join(name))
                .unwrap();
        }
        for database in [name, "goals_1.sqlite"] {
            root.clone_from(
                &root,
                &source.join(database),
                &fixture.target.join(database),
            )
            .unwrap();
        }
        python(
            r#"
import sqlite3,sys
for path,thread,memory in [(sys.argv[1],sys.argv[3],'Source memory'),(sys.argv[2],'host-thread','Host memory')]:
    with sqlite3.connect(path) as db:
        db.execute('INSERT INTO stage1_outputs(thread_id,source_updated_at,raw_memory,rollout_summary,generated_at) VALUES (?,100,?,?,150)',(thread,memory,'Summary'))
        db.execute('INSERT INTO jobs(kind,job_key,status,retry_remaining) VALUES (?,?,?,?)',('memory_stage1',thread,'pending',2))
        db.execute('INSERT INTO jobs(kind,job_key,status,retry_remaining,input_watermark) VALUES (?,?,?,?,?)',('memory_consolidate_global','global','done',2,555))
for path,thread,objective in [(sys.argv[4],sys.argv[3],'Source objective'),(sys.argv[5],'host-thread','Host objective')]:
    with sqlite3.connect(path) as db:
        db.execute('INSERT INTO thread_goals(thread_id,goal_id,objective,status,token_budget,tokens_used,time_used_seconds,created_at_ms,updated_at_ms) VALUES (?,?,?,\'active\',100,20,3,10,20)',(thread,thread,objective))
        db.execute('INSERT INTO thread_goal_continuation_deferrals(thread_id) VALUES (?)',(thread,))
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE jobs SET input_watermark=777 WHERE job_key=\'global\'')
print('{}')
"#,
            &[
                source.join(name),
                fixture.target.join(name),
                THREAD.into(),
                source.join("goals_1.sqlite"),
                fixture.target.join("goals_1.sqlite"),
            ],
        );
        let host_memory = fixture.target.join(directory);
        let source_memory = source.join(directory);
        let source_files = [
            ("MEMORY.md", "Curated source knowledge absent from stage1"),
            (
                "memory_summary.md",
                "v1\n## User Profile\nSource\n## User preferences\n## General Tips\n## What's in Memory\n",
            ),
            ("raw_memories.md", "Source raw memories"),
            ("rollout_summaries/shared.md", "Source shared summary"),
        ];
        let host_files = source_files.map(|(name, contents)| {
            let host = if name == "memory_summary.md" {
                contents.replace("Source", "Host")
            } else {
                format!("Host {name}")
            };
            (name, host)
        });
        for ((name, contents), (_, host_contents)) in source_files.iter().zip(&host_files) {
            root.replace(&source_memory.join(name), contents.as_bytes())
                .unwrap();
            root.replace(&host_memory.join(name), host_contents.as_bytes())
                .unwrap();
        }
        for (memory, owner) in [(&source_memory, "source"), (&host_memory, "host")] {
            root.replace(&memory.join(".git/HEAD"), owner.as_bytes())
                .unwrap();
            root.replace(&memory.join("phase2_workspace_diff.md"), owner.as_bytes())
                .unwrap();
        }
        root.replace(
            &source_memory.join(".git/objects/source-only"),
            b"source git object",
        )
        .unwrap();
        let memory_file = Path::new(directory).join("rollout_summaries/source.md");
        root.replace(&source.join(&memory_file), b"Source unique summary")
            .unwrap();
        let source_before = source_bytes(&fixture.source);
        let host_before = std::fs::read(fixture.target.join(name)).unwrap();
        let goals_before = std::fs::read(fixture.target.join("goals_1.sqlite")).unwrap();
        let paths = crate::config::HostPaths::from_home(fixture.home.path().to_owned()).unwrap();
        let backup = crate::runtime::install::claude_state::ClaudeStateBackup::new(&paths);
        backup
            .capture(&fixture.claude_home, &fixture.target)
            .unwrap();
        run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
        assert_eq!(
            std::fs::read(fixture.target.join(&memory_file)).unwrap(),
            b"Source unique summary"
        );
        let extension = host_memory
            .join("extensions")
            .join(format!("remotecoder-retired-{ACCOUNT}"));
        assert!(
            !std::fs::read(extension.join("instructions.md"))
                .unwrap()
                .is_empty()
        );
        for ((name, contents), (_, host_contents)) in source_files.iter().zip(&host_files) {
            assert_eq!(
                std::fs::read(extension.join("resources/original").join(name)).unwrap(),
                contents.as_bytes()
            );
            assert_eq!(
                std::fs::read(host_memory.join(name)).unwrap(),
                host_contents.as_bytes()
            );
        }
        assert_eq!(
            std::fs::read(host_memory.join(".git/HEAD")).unwrap(),
            b"host"
        );
        assert!(!host_memory.join(".git/objects/source-only").exists());
        assert_eq!(
            std::fs::read(source_memory.join(".git/HEAD")).unwrap(),
            b"source"
        );
        assert_eq!(
            std::fs::read(source_memory.join(".git/objects/source-only")).unwrap(),
            b"source git object"
        );
        assert_eq!(
            std::fs::read(host_memory.join("phase2_workspace_diff.md")).unwrap(),
            b"host"
        );
        let adopted = python(
            r#"
import json,sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    result={'memories':db.execute('SELECT thread_id,raw_memory FROM stage1_outputs ORDER BY thread_id').fetchall(),'jobs':db.execute('SELECT kind,job_key,status,retry_remaining,input_watermark FROM jobs ORDER BY kind,job_key').fetchall()}
with sqlite3.connect(sys.argv[2]) as db:
    result['goals']=db.execute('SELECT thread_id,objective,status,token_budget,tokens_used,time_used_seconds FROM thread_goals ORDER BY thread_id').fetchall()
    result['deferrals']=db.execute('SELECT thread_id FROM thread_goal_continuation_deferrals ORDER BY thread_id').fetchall()
print(json.dumps(result))
"#,
            &[
                fixture.target.join(name),
                fixture.target.join("goals_1.sqlite"),
            ],
        );
        assert_eq!(
            adopted["memories"],
            json!([[THREAD, "Source memory"], ["host-thread", "Host memory"]])
        );
        assert_eq!(
            adopted["jobs"],
            json!([
                ["memory_consolidate_global", "global", "done", 2, 555],
                ["memory_stage1", THREAD, "pending", 2, null],
                ["memory_stage1", "host-thread", "pending", 2, null]
            ])
        );
        assert_eq!(
            adopted["goals"],
            json!([
                [THREAD, "Source objective", "active", 100, 20, 3],
                ["host-thread", "Host objective", "active", 100, 20, 3]
            ])
        );
        assert_eq!(adopted["deferrals"], json!([[THREAD], ["host-thread"]]));
        let receipt_before = std::fs::read(paths.state(RECEIPT)).unwrap();
        let adopted_before = std::fs::read(fixture.target.join(name)).unwrap();
        run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
        assert_eq!(std::fs::read(paths.state(RECEIPT)).unwrap(), receipt_before);
        assert_eq!(
            std::fs::read(fixture.target.join(name)).unwrap(),
            adopted_before
        );
        backup.restore().unwrap();
        assert_eq!(
            std::fs::read(fixture.target.join(name)).unwrap(),
            host_before
        );
        assert_eq!(
            std::fs::read(fixture.target.join("goals_1.sqlite")).unwrap(),
            goals_before
        );
        assert!(!fixture.target.join(&memory_file).exists());
        assert!(!extension.join("instructions.md").exists());
        assert_eq!(source_bytes(&fixture.source), source_before);
    }
}

#[test]
fn snapshot_covers_memory_collisions_created_by_an_earlier_profile() {
    let fixture = Fixture::new();
    let root = Root::open(fixture.home.path()).unwrap();
    let second_id = "22222222-2222-2222-2222-222222222222";
    let first = fixture.source.join("c/memories/MEMORY.md");
    let second = fixture
        .home
        .path()
        .join(".rca")
        .join(second_id.replace('-', ""))
        .join("c/memories/MEMORY.md");
    root.replace(&first, b"First profile memory").unwrap();
    root.replace(&second, b"Second profile memory").unwrap();
    let paths = crate::config::HostPaths::from_home(fixture.home.path().to_owned()).unwrap();
    let backup = crate::runtime::install::claude_state::ClaudeStateBackup::new(&paths);
    backup
        .capture(&fixture.claude_home, &fixture.target)
        .unwrap();
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    let extension = fixture
        .target
        .join("memories/extensions")
        .join(format!("remotecoder-retired-{second_id}"));
    let resource = extension.join("resources/original/MEMORY.md");
    assert_eq!(std::fs::read(&resource).unwrap(), b"Second profile memory");
    assert!(extension.join("instructions.md").exists());
    assert_eq!(
        std::fs::read(fixture.target.join("memories/MEMORY.md")).unwrap(),
        b"First profile memory"
    );
    backup.restore().unwrap();
    assert!(!fixture.target.join("memories/MEMORY.md").exists());
    assert!(!resource.exists());
    assert!(!extension.join("instructions.md").exists());
    assert_eq!(std::fs::read(first).unwrap(), b"First profile memory");
    assert_eq!(std::fs::read(second).unwrap(), b"Second profile memory");
}

#[test]
fn native_schema_drift_is_rejected_before_any_source_history_is_copied() {
    let fixture = Fixture::new();
    fixture.native();
    let source = fixture.source.join("c");
    python(
        "import sqlite3,sys\nwith sqlite3.connect(sys.argv[1]) as db: db.execute('CREATE TABLE unexpected_schema_change(value TEXT)')\nprint('{}')",
        &[source.join("state_5.sqlite")],
    );
    let original = source_bytes(&fixture.source);
    let error = run(fixture.home.path(), &fixture.target, &fixture.claude_home)
        .err()
        .unwrap()
        .to_string();
    assert!(error.contains("Unsupported pinned Codex schema"), "{error}");
    assert!(!fixture.target.join("state_5.sqlite").exists());
    assert!(!fixture.target.join("sessions").exists());
    assert_eq!(source_bytes(&fixture.source), original);
}

#[test]
fn unclassified_source_databases_are_rejected_before_any_source_history_is_copied() {
    let fixture = Fixture::new();
    fixture.native();
    let source = fixture.source.join("c");
    python(
        "import sqlite3,sys\nfor path in sys.argv[1:]:\n    with sqlite3.connect(path) as db: db.execute('CREATE TABLE value(id TEXT)')\nprint('{}')",
        &[
            source.join("logs_2.sqlite"),
            source.join("agent_message_board_1.sqlite"),
        ],
    );
    let original = source_bytes(&fixture.source);
    let error = run(fixture.home.path(), &fixture.target, &fixture.claude_home)
        .err()
        .unwrap()
        .to_string();
    assert!(
        error.contains(&format!(
            "Unclassified Codex databases in {}: agent_message_board_1.sqlite\n",
            source.display()
        )),
        "{error}"
    );
    assert!(!fixture.target.join("state_5.sqlite").exists());
    assert!(!fixture.target.join("sessions").exists());
    assert_eq!(source_bytes(&fixture.source), original);
}

#[test]
fn fresh_native_history_adopts_into_upgraded_layout_without_swapping_named_columns() {
    let fixture = Fixture::new();
    let manifest = fixture.native();
    let source = fixture.source.join("c/thread_history_1.sqlite");
    let target = fixture.target.join("thread_history_1.sqlite");
    let ddl = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("test-fixtures/codex-adoption/upgraded-history-tables.json");
    let layouts = python(
        r#"
import json,pathlib,sqlite3,sys
source,target,ddl=map(pathlib.Path,sys.argv[1:])
replacement=json.loads(ddl.read_text())
with sqlite3.connect(source.as_uri()+'?mode=ro',uri=True) as incoming, sqlite3.connect(target) as host:
    schema=incoming.execute("SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END,type,name").fetchall()
    for kind,name,sql in schema:
        host.execute(replacement.get(name,sql) if kind=='table' else sql)
    columns=[row[1] for row in incoming.execute('PRAGMA table_info("_sqlx_migrations")')]
    names=','.join('"'+column+'"' for column in columns)
    host.executemany(f'INSERT INTO _sqlx_migrations ({names}) VALUES ({",".join("?" for _ in columns)})',incoming.execute(f'SELECT {names} FROM _sqlx_migrations'))
    layouts={}
    for table in replacement:
        layouts[table]={'source':[row[1] for row in incoming.execute(f'PRAGMA table_info("{table}")')],'target':[row[1] for row in host.execute(f'PRAGMA table_info("{table}")')]}
    print(json.dumps(layouts))
"#,
        &[source.clone(), target.clone(), ddl],
    );
    for table in ["thread_items", "thread_turns"] {
        assert_ne!(layouts[table]["source"], layouts[table]["target"]);
    }
    run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
    let counts = python(
        r#"
import json,pathlib,sqlite3,sys
source,target=map(pathlib.Path,sys.argv[1:])
with sqlite3.connect(source.as_uri()+'?mode=ro',uri=True) as incoming, sqlite3.connect(target.as_uri()+'?mode=ro',uri=True) as host:
    result={}
    tables=[row[0] for row in incoming.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name<>'_sqlx_migrations' ORDER BY name")]
    for table in tables:
        quoted='"'+table.replace('"','""')+'"'
        columns=[row[1] for row in incoming.execute(f'PRAGMA table_info({quoted})')]
        named=','.join('"'+column.replace('"','""')+'"' for column in columns)
        query=f'SELECT {named} FROM {quoted} ORDER BY {named}'
        expected=incoming.execute(query).fetchall()
        actual=host.execute(query).fetchall()
        if expected!=actual:
            raise AssertionError(f'{table}: adopted rows differ when selected by original column names')
        result[table]=len(actual)
    print(json.dumps(result))
"#,
        &[source, target],
    );
    let threads = manifest["threads"].as_array().unwrap();
    assert_eq!(
        counts["thread_turns"].as_u64().unwrap(),
        threads
            .iter()
            .map(|thread| thread["projectionTurns"].as_u64().unwrap())
            .sum::<u64>()
    );
    assert_eq!(
        counts["thread_items"].as_u64().unwrap(),
        threads
            .iter()
            .map(|thread| thread["projectionItems"].as_u64().unwrap())
            .sum::<u64>()
    );
}

#[tokio::test]
async fn original_read_scopes_survive_native_adoption_profile_removal_and_both_baseline_orders() {
    use crate::conversation_marks::{Change, ConversationMarksStore, Location};
    const CLAUDE_ACCOUNT: &str = "22222222-2222-2222-2222-222222222222";
    const HOST_CODEX: &str = "01a00000-0000-7000-8000-000000000001";
    const HOST_CLAUDE: &str = "11111111-2222-4333-8444-555555555555";
    const SOURCE_CLAUDE: &str = "22222222-3333-4444-8555-666666666666";
    for (host_baseline, source_baseline) in [(100, 300), (300, 100)] {
        let fixture = Fixture::new();
        let manifest = fixture.native();
        let root = Root::open(fixture.home.path()).unwrap();
        root.clone_from(
            &root,
            &fixture.source.join("c/state_5.sqlite"),
            &fixture.target.join("state_5.sqlite"),
        )
        .unwrap();
        python(
            "import sqlite3,sys\nwith sqlite3.connect(sys.argv[1]) as db:\n db.execute('DELETE FROM threads WHERE id != ?', (sys.argv[2],))\n db.execute('UPDATE threads SET id=?', (sys.argv[3],))\nprint('{}')",
            &[
                fixture.target.join("state_5.sqlite"),
                THREAD.into(),
                HOST_CODEX.into(),
            ],
        );
        let host_claude = fixture.claude_home.join("projects/project");
        std::fs::create_dir_all(&host_claude).unwrap();
        std::fs::write(host_claude.join(format!("{HOST_CLAUDE}.jsonl")), b"{}").unwrap();
        let retired = fixture
            .home
            .path()
            .join(".rca")
            .join(CLAUDE_ACCOUNT.replace('-', ""));
        std::fs::create_dir_all(retired.join("claude/projects/project")).unwrap();
        std::fs::write(
            retired.join(format!("claude/projects/project/{SOURCE_CLAUDE}.jsonl")),
            b"{}",
        )
        .unwrap();
        root.write_json(&retired.join("state/conversation-marks.v3.json"), &json!({"schemaVersion":3,"revision":1,"readBaseline":100,"threads":{"claude_source-mark-only":{"revision":1,"markedUnread":true}}})).unwrap();
        fixture.state(false, "claude-profile-migration.json", &json!({"retiredIds":[CLAUDE_ACCOUNT],"sessions":[SOURCE_CLAUDE],"conflicts":[],"memoryIndexes":[],"metadataThreads":[],"complete":true,"completed":[CLAUDE_ACCOUNT],"pending":[]}));
        fixture.state(false, "conversation-marks.v3.json", &json!({"schemaVersion":3,"revision":1,"readBaseline":host_baseline,"threads":{"host-mark-only":{"revision":1,"markedUnread":true},"unrelated":{"revision":1,"markedUnread":true}}}));
        fixture.state(true, "conversation-marks.v3.json", &json!({"schemaVersion":3,"revision":1,"readBaseline":source_baseline,"threads":{"source-mark-only":{"revision":1,"markedUnread":true}}}));
        run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
        let state = fixture.home.path().join(".remote-coder");
        let scopes = read_scopes(&state).unwrap();
        let source_ids: BTreeSet<String> = manifest["threads"]
            .as_array()
            .unwrap()
            .iter()
            .map(|thread| thread["id"].as_str().unwrap().to_owned())
            .chain(std::iter::once("source-mark-only".into()))
            .collect();
        assert_eq!(scopes[ACCOUNT], source_ids);
        assert_eq!(
            scopes["default"],
            BTreeSet::from([
                HOST_CODEX.into(),
                crate::providers::claude::claude_thread_id(HOST_CLAUDE),
                "host-mark-only".into(),
                "unrelated".into()
            ])
        );
        assert_eq!(
            scopes[CLAUDE_ACCOUNT],
            BTreeSet::from([
                crate::providers::claude::claude_thread_id(SOURCE_CLAUDE),
                "claude_source-mark-only".into()
            ])
        );
        assert!(!scopes["default"].contains(THREAD));
        assert!(!scopes[ACCOUNT].contains(HOST_CODEX));
        let receipt_before = std::fs::read(state.join(RECEIPT)).unwrap();
        std::fs::remove_dir_all(&fixture.source).unwrap();
        std::fs::remove_dir_all(retired).unwrap();
        std::fs::write(
            host_claude.join("33333333-4444-4555-8666-777777777777.jsonl"),
            b"{}",
        )
        .unwrap();
        run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
        assert_eq!(std::fs::read(state.join(RECEIPT)).unwrap(), receipt_before);
        let marks = ConversationMarksStore::new(Some(Location {
            directory: state.clone(),
            handoff_records: state.join("conversation-handoffs.json"),
        }));
        marks
            .update(
                vec![Change::MarkUnread {
                    thread_id: "new-thread".into(),
                }],
                400,
            )
            .await
            .unwrap();
        for scope in [ACCOUNT, CLAUDE_ACCOUNT, "default"] {
            let before = marks.read(400).await.unwrap();
            let delta = marks
                .update(
                    vec![Change::MarkRetiredScopeRead {
                        scope_id: scope.into(),
                        through: 200,
                    }],
                    400,
                )
                .await
                .unwrap()
                .unwrap();
            assert_eq!(delta.read_baseline, 100);
            assert!(
                delta
                    .threads
                    .keys()
                    .all(|thread| scopes[scope].contains(thread))
            );
            let after = marks.read(400).await.unwrap();
            assert_eq!(after.threads["new-thread"], before.threads["new-thread"]);
            for (thread, mark) in &before.threads {
                if !scopes[scope].contains(thread) {
                    assert_eq!(&after.threads[thread], mark);
                }
            }
            for thread in &scopes[scope] {
                let prior_seen = before
                    .threads
                    .get(thread)
                    .and_then(|marks| marks.seen_through)
                    .unwrap_or(before.read_baseline);
                assert_eq!(
                    after.threads[thread].seen_through,
                    Some(prior_seen.max(200))
                );
                assert!(!after.threads[thread].marked_unread);
            }
            assert!(
                marks
                    .update(
                        vec![Change::MarkRetiredScopeRead {
                            scope_id: scope.into(),
                            through: 200
                        }],
                        500
                    )
                    .await
                    .unwrap()
                    .is_none()
            );
        }
    }
}

#[test]
fn read_scopes_include_native_filesystem_fallbacks_without_index_rows() {
    let fixture = Fixture::new();
    let root = Root::open(fixture.home.path()).unwrap();
    let session = fixture.target.join("sessions/2026/10/17");
    let archive = fixture.source.join("c/archived_sessions");
    std::fs::create_dir_all(&session).unwrap();
    std::fs::create_dir_all(&archive).unwrap();
    let ids = [
        "01a00000-0000-7000-8000-000000000001",
        "01a00000-0000-7000-8000-000000000002",
    ];
    std::fs::write(
        session.join(format!("rollout-2026-10-17T20-30-00-{}.jsonl", ids[0])),
        b"{}",
    )
    .unwrap();
    std::fs::write(
        archive.join(format!(
            "rollout-2026-10-17T20-30-00-{}_{}.jsonl.zst",
            ids[1], ids[0]
        )),
        b"compressed fixture name",
    )
    .unwrap();
    std::fs::write(archive.join("rollout-invalid.jsonl"), b"{}").unwrap();
    let scopes = capture_read_scopes(
        &root,
        fixture.home.path(),
        &fixture.target,
        &fixture.claude_home,
        &profiles(fixture.home.path()).unwrap(),
    )
    .unwrap();
    assert_eq!(scopes["default"], BTreeSet::from([ids[0].into()]));
    assert_eq!(scopes[ACCOUNT], BTreeSet::from([ids[1].into()]));
    assert!(!fixture.target.join("state_5.sqlite").exists());
    assert!(!fixture.source.join("c/state_5.sqlite").exists());
}

#[test]
fn rollout_only_scopes_preserve_implicit_read_and_attention_thresholds_without_covering_future_sources()
 {
    const HOST: &str = "01a00000-0000-7000-8000-000000000001";
    const SOURCE: &str = "01a00000-0000-7000-8000-000000000002";
    const FUTURE: &str = "01a00000-0000-7000-8000-000000000003";
    const LATER: &str = "33333333-3333-3333-3333-333333333333";
    for (host_baseline, source_baseline) in [(100, 300), (300, 100)] {
        let fixture = Fixture::new();
        let root = Root::open(fixture.home.path()).unwrap();
        let later = fixture
            .home
            .path()
            .join(".rca")
            .join(LATER.replace('-', ""));
        for (home, id) in [
            (&fixture.target, HOST),
            (&fixture.source.join("c"), SOURCE),
            (&later.join("c"), FUTURE),
        ] {
            let directory = home.join("archived_sessions");
            std::fs::create_dir_all(&directory).unwrap();
            std::fs::write(
                directory.join(format!("rollout-2026-10-17T20-30-00-{id}.jsonl")),
                b"{}",
            )
            .unwrap();
        }
        fixture.state(
            false,
            "conversation-marks.v3.json",
            &json!({"schemaVersion":3,"revision":1,"readBaseline":host_baseline,"threads":{}}),
        );
        fixture.state(
            true,
            "conversation-marks.v3.json",
            &json!({"schemaVersion":3,"revision":1,"readBaseline":source_baseline,"threads":{}}),
        );
        root.write_json(
            &later.join("state/conversation-marks.v3.json"),
            &json!({"schemaVersion":3,"revision":1,"readBaseline":50,"threads":{}}),
        )
        .unwrap();
        let receipt = run(fixture.home.path(), &fixture.target, &fixture.claude_home).unwrap();
        let first = planned(
            receipt.profiles[ACCOUNT].writes.as_ref().unwrap(),
            "conversation-marks.v3.json",
        );
        assert!(first["threads"].get(FUTURE).is_none());
        let final_marks: Value = serde_json::from_slice(
            &std::fs::read(
                fixture
                    .home
                    .path()
                    .join(".remote-coder/conversation-marks.v3.json"),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(final_marks["readBaseline"], 50);
        for (thread, baseline) in [(HOST, host_baseline), (SOURCE, source_baseline)] {
            let seen = final_marks["threads"][thread]["seenThrough"]
                .as_i64()
                .unwrap();
            assert_eq!(seen, baseline);
            assert_eq!(200 > seen, 200 > baseline);
        }
        assert!(final_marks["threads"].get(FUTURE).is_none());
    }
}

#[test]
fn unreadable_native_rollout_scope_fails_without_recording_empty_evidence() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    let day = fixture.target.join("sessions/2026/10/17");
    std::fs::create_dir_all(&day).unwrap();
    std::fs::write(
        day.join("rollout-2026-10-17T20-30-00-01a00000-0000-7000-8000-000000000001.jsonl"),
        b"{}",
    )
    .unwrap();
    std::fs::set_permissions(&day, std::fs::Permissions::from_mode(0o0)).unwrap();
    let result = run(fixture.home.path(), &fixture.target, &fixture.claude_home);
    std::fs::set_permissions(&day, std::fs::Permissions::from_mode(0o700)).unwrap();
    let error = format!("{:#}", result.err().expect("Unreadable scope must fail"));
    assert!(error.contains("Permission denied"), "{error}");
    assert!(
        !fixture
            .home
            .path()
            .join(".remote-coder")
            .join(RECEIPT)
            .exists()
    );
}

fn large_marks(prefix: &str, count: usize) -> Value {
    let threads: serde_json::Map<String, Value> = (0..count)
        .map(|index| {
            (
                format!("{prefix}-{index:05}"),
                json!({"revision":1,"pinName":"x".repeat(256)}),
            )
        })
        .collect();
    json!({"schemaVersion":3,"revision":1,"readBaseline":100,"threads":threads})
}

#[test]
fn merged_marks_refuse_capacity_before_any_staged_gateway_write() {
    let fixture = Fixture::new();
    let host = large_marks("host", 15000);
    let incoming = large_marks("source", 15000);
    crate::conversation_marks::validate_migration_document(&host).unwrap();
    crate::conversation_marks::validate_migration_document(&incoming).unwrap();
    let host_marks = fixture.state(false, "conversation-marks.v3.json", &host);
    let source_marks = fixture.state(true, "conversation-marks.v3.json", &incoming);
    let metadata_path = fixture.state(
        false,
        "session-metadata-v2.json",
        &json!({"schemaVersion":1,"records":{(THREAD):metadata("host",10,40)}}),
    );
    fixture.state(
        true,
        "session-metadata-v2.json",
        &json!({"schemaVersion":1,"records":{(THREAD):metadata("source",20,3)}}),
    );
    let originals = [&host_marks, &source_marks, &metadata_path]
        .into_iter()
        .map(|path| (path.clone(), std::fs::read(path).unwrap()))
        .collect::<Vec<_>>();
    let error = run(fixture.home.path(), &fixture.target, &fixture.claude_home)
        .err()
        .unwrap()
        .to_string();
    assert!(
        error.contains("conversation marks capacity exceeded"),
        "{error}"
    );
    for (path, bytes) in originals {
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
    assert!(!is_settled(fixture.home.path()).unwrap());
}

#[test]
fn replayed_marks_validate_capacity_and_schema_before_any_staged_gateway_write() {
    for invalid in [
        large_marks("oversized", 30000),
        json!({"schemaVersion":99,"revision":0,"readBaseline":0,"threads":{}}),
    ] {
        let fixture = Fixture::new();
        let root = Root::open(fixture.home.path()).unwrap();
        let destination = fixture.state(
            false,
            "conversation-marks.v3.json",
            &large_marks("original", 1),
        );
        let metadata = fixture.state(false, "session-metadata-v2.json", &json!({"original":true}));
        let receipt = Receipt {
            profiles: BTreeMap::from([(
                ACCOUNT.into(),
                Adoption {
                    imported: true,
                    writes: Some(vec![
                        StateWrite {
                            path: metadata.clone(),
                            value: json!({"replaced":true}),
                        },
                        StateWrite {
                            path: destination.clone(),
                            value: invalid,
                        },
                    ]),
                    ..Adoption::default()
                },
            )]),
            ..Receipt::default()
        };
        root.write_json(
            &fixture.home.path().join(".remote-coder").join(RECEIPT),
            &receipt,
        )
        .unwrap();
        let original = std::fs::read(&destination).unwrap();
        let metadata_original = std::fs::read(&metadata).unwrap();
        assert!(run(fixture.home.path(), &fixture.target, &fixture.claude_home).is_err());
        assert_eq!(std::fs::read(destination).unwrap(), original);
        assert_eq!(std::fs::read(metadata).unwrap(), metadata_original);
        assert!(!is_settled(fixture.home.path()).unwrap());
    }
}
