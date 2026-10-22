use std::collections::BTreeMap;
use std::fs;
use std::io::Write;

use serde_json::{Value, json};
use tempfile::TempDir;

use super::*;
use crate::providers::claude::conversation_index::Store;
use crate::providers::claude::translate::TurnTranslator;
use std::path::PathBuf;

const FIXTURE_SESSION: &str = "11111111-2222-3333-4444-555555555555";
const FIXTURE_THREAD: &str = "claude_11111111-2222-3333-4444-555555555555";
const FIXTURE_CWD: &str = "/tmp/fixture-work";
const CWD: &str = "/repo/app";

fn fixture(source: &str) -> Vec<Value> {
    source
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("fixture line is JSON"))
        .collect()
}

fn write_session(home: &Path, cwd: &str, uuid: &str, records: &[Value]) -> PathBuf {
    let project = home
        .join("projects")
        .join(crate::providers::claude::project_slug(cwd));
    fs::create_dir_all(&project).unwrap();
    let path = project.join(format!("{uuid}.jsonl"));
    let mut file = fs::File::create(&path).unwrap();
    for record in records {
        writeln!(file, "{record}").unwrap();
    }
    path
}

fn append(path: &Path, record: &Value) {
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    writeln!(file, "{record}").unwrap();
}

fn project(home: &Path, thread_id: &str, path: &Path, active: Option<&str>) -> (Projection, File) {
    let index = crate::providers::claude::conversation_index::read(home, thread_id).unwrap();
    let file = File::open(path).unwrap();
    let length = file.metadata().unwrap().len();
    (
        Projection::build(&file, length, &index, active).unwrap(),
        file,
    )
}

#[test]
fn a_complete_record_without_its_newline_is_not_part_of_the_projection() {
    let home = tempfile::tempdir().unwrap();
    let prompt = |uuid: &str| {
        json!({"type":"user","uuid":uuid,"timestamp":"2026-09-13T10:00:00Z","cwd":CWD,
            "message":{"role":"user","content":uuid}})
    };
    let path = write_session(home.path(), CWD, "unterminated", &[prompt("first")]);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    write!(file, "{}", prompt("second")).unwrap();

    let (projection, _) = project(home.path(), "claude_unterminated", &path, None);
    assert_eq!(projection.items.len(), 1);

    writeln!(file).unwrap();
    let (projection, _) = project(home.path(), "claude_unterminated", &path, None);
    assert_eq!(projection.items.len(), 2);
}

fn items_params(
    thread_id: &str,
    turn_id: Option<&str>,
    cursor: Option<String>,
    limit: Option<u32>,
    direction: Option<SortDirection>,
) -> ItemsListParams {
    ItemsListParams {
        thread_id: thread_id.to_string(),
        turn_id: turn_id.map(str::to_string),
        cursor,
        limit,
        sort_direction: direction,
    }
}

fn turns_params(
    thread_id: &str,
    cursor: Option<String>,
    limit: Option<u32>,
    view: Option<ItemsView>,
) -> TurnsListParams {
    TurnsListParams {
        thread_id: thread_id.to_string(),
        cursor,
        limit,
        sort_direction: None,
        items_view: view,
    }
}

fn walk(
    projection: &Projection,
    file: &File,
    thread_id: &str,
    turn_id: Option<&str>,
    limit: u32,
    direction: SortDirection,
) -> Vec<Value> {
    let mut entries = Vec::new();
    let mut cursor = None;
    loop {
        let page = projection
            .items_page(
                file,
                &items_params(thread_id, turn_id, cursor, Some(limit), Some(direction)),
            )
            .unwrap();
        let data = page["data"].as_array().unwrap();
        assert!(data.len() <= limit as usize);
        entries.extend(data.iter().cloned());
        match page["nextCursor"].as_str() {
            Some(next) => cursor = Some(next.to_string()),
            None => return entries,
        }
    }
}

fn ids(entries: &[Value]) -> Vec<String> {
    entries
        .iter()
        .map(|entry| entry["item"]["id"].as_str().unwrap().to_string())
        .collect()
}

fn texts(entries: &[Value]) -> Vec<String> {
    entries
        .iter()
        .filter_map(|entry| {
            let item = &entry["item"];
            match item["type"].as_str() {
                Some("userMessage") => item["content"][0]["text"].as_str(),
                Some("agentMessage") => item["text"].as_str(),
                _ => None,
            }
        })
        .map(str::to_string)
        .collect()
}

fn without_duration(mut item: Value) -> Value {
    if let Some(item) = item.as_object_mut() {
        item.remove("durationMs");
    }
    item
}

fn invalid_request(result: Result<Value, HistoryError>) -> String {
    match result {
        Err(HistoryError::InvalidRequest(message) | HistoryError::InvalidCursor(message)) => {
            message
        }
        other => panic!("expected an invalid request, got {other:?}"),
    }
}

fn three_turns() -> Vec<Value> {
    let prompt = |uuid: &str, text: &str, second: u32| json!({"type":"user","uuid":uuid,"cwd":CWD,"timestamp":format!("2026-08-16T13:35:{second:02}.000Z"),"message":{"role":"user","content":text}});
    let tool = |uuid: &str, message: &str, id: &str, second: u32| json!({"type":"assistant","uuid":uuid,"timestamp":format!("2026-08-16T13:35:{second:02}.000Z"),"message":{"id":message,"role":"assistant","content":[{"type":"tool_use","id":id,"name":"Bash","input":{"command":format!("echo {id}")}}]}});
    let result = |uuid: &str, id: &str, second: u32| json!({"type":"user","uuid":uuid,"timestamp":format!("2026-08-16T13:35:{second:02}.000Z"),"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":id,"content":id}]}});
    let text = |uuid: &str, message: &str, text: &str, second: u32| json!({"type":"assistant","uuid":uuid,"timestamp":format!("2026-08-16T13:35:{second:02}.000Z"),"message":{"id":message,"role":"assistant","content":[{"type":"text","text":text}]}});
    vec![
        prompt("P1", "first", 1),
        tool("a1", "m1", "t1", 2),
        result("r1", "t1", 3),
        text("a2", "m1", "one", 4),
        prompt("P2", "second", 10),
        text("a3", "m2", "two", 11),
        prompt("P3", "third", 20),
        tool("a4", "m3", "t3", 21),
        result("r3", "t3", 22),
        tool("a5", "m3", "t4", 23),
        result("r4", "t4", 24),
        text("a6", "m3", "three", 25),
    ]
}

#[tokio::test]
async fn a_descending_walk_returns_every_live_item_once_in_ordinal_order() {
    let home = TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let session = fixture(include_str!(
        "../../../../tests/fixtures/claude-session-narration.jsonl"
    ));
    let path = write_session(home.path(), FIXTURE_CWD, FIXTURE_SESSION, &session);
    let turn = "claude-turn-1790000000000-1";
    let mut translator = TurnTranslator::new(
        FIXTURE_THREAD.to_string(),
        turn.to_string(),
        FIXTURE_CWD.to_string(),
        None,
        1_790_000_000_000,
        std::sync::Arc::default(),
    );
    let mut frames = vec![translator.turn_started()];
    frames.extend(translator.handle(&session[0]).notifications);
    for line in fixture(include_str!(
        "../../../../tests/fixtures/claude-stream-narration.jsonl"
    )) {
        frames.extend(translator.handle(&line).notifications);
    }
    frames.push(translator.turn_completed("completed", None, None));
    let mut live = BTreeMap::new();
    for frame in &mut frames {
        store.record(frame).await.unwrap();
        if frame["method"] == "item/completed" {
            live.insert(
                frame["params"]["startedAtOrdinal"].as_i64().unwrap(),
                (
                    frame["params"]["startedAtMs"].clone(),
                    frame["params"]["item"].clone(),
                ),
            );
        }
    }
    assert!(live.len() > 5, "fixture must exercise several item kinds");

    let (projection, file) = project(home.path(), FIXTURE_THREAD, &path, None);
    let mut walked = walk(
        &projection,
        &file,
        FIXTURE_THREAD,
        None,
        2,
        SortDirection::Desc,
    );
    walked.reverse();

    assert_eq!(
        walked
            .iter()
            .map(|entry| entry["startedAtOrdinal"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        live.keys().copied().collect::<Vec<_>>()
    );
    assert_eq!(
        walked
            .iter()
            .map(|entry| (
                entry["startedAtMs"].clone(),
                without_duration(entry["item"].clone())
            ))
            .collect::<Vec<_>>(),
        live.values()
            .map(|(started, item)| (started.clone(), without_duration(item.clone())))
            .collect::<Vec<_>>()
    );
    assert!(
        walked
            .iter()
            .all(|entry| entry["turnId"] == turn && entry["isComplete"] == true)
    );
    assert!(
        ids(&walked).contains(&"msg_011CfLQhAj8nGscUV3gSRQfR#1".to_string())
            && ids(&walked).contains(&"msg_011CfLQhdVxHgWbos9PKRToC#0".to_string())
    );
    let ascending = walk(
        &projection,
        &file,
        FIXTURE_THREAD,
        None,
        3,
        SortDirection::Asc,
    );
    assert_eq!(ids(&ascending), ids(&walked));
}

#[test]
fn per_turn_pages_agree_with_the_thread_wide_walk() {
    let home = TempDir::new().unwrap();
    let path = write_session(home.path(), CWD, "paged", &three_turns());
    let thread = "claude_paged";
    let (projection, file) = project(home.path(), thread, &path, None);

    let thread_wide = walk(&projection, &file, thread, None, 3, SortDirection::Asc);
    assert_eq!(
        ids(&thread_wide),
        ["P1", "t1", "m1#1", "P2", "m2#0", "P3", "t3", "t4", "m3#2"]
    );
    let mut descending = walk(&projection, &file, thread, None, 4, SortDirection::Desc);
    descending.reverse();
    assert_eq!(descending, thread_wide);

    let turns = projection
        .turns_page(
            &file,
            &turns_params(thread, None, None, Some(ItemsView::Full)),
        )
        .unwrap();
    let turns = turns["data"].as_array().unwrap();
    assert_eq!(
        turns
            .iter()
            .map(|turn| turn["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["claude-turn-3", "claude-turn-2", "claude-turn-1"]
    );
    let mut per_turn = Vec::new();
    for turn in turns.iter().rev() {
        let turn_id = turn["id"].as_str().unwrap();
        let mut entries = walk(
            &projection,
            &file,
            thread,
            Some(turn_id),
            1,
            SortDirection::Desc,
        );
        entries.reverse();
        assert!(entries.iter().all(|entry| entry["turnId"] == turn_id));
        assert_eq!(
            entries
                .iter()
                .map(|entry| entry["item"].clone())
                .collect::<Vec<_>>(),
            turn["items"].as_array().unwrap().clone()
        );
        per_turn.extend(entries);
    }
    assert_eq!(per_turn, thread_wide);
    assert_eq!(
        thread_wide
            .iter()
            .find(|entry| entry["item"]["id"] == "t1")
            .unwrap()["item"]["durationMs"],
        1_000
    );
}

#[test]
fn thread_turns_beyond_their_byte_budget_are_a_capacity_error_not_a_partial_list() {
    let home = TempDir::new().unwrap();
    let path = write_session(home.path(), CWD, "budget", &three_turns());
    let (projection, file) = project(home.path(), "claude_budget", &path, None);
    let turns = projection.thread_turns(&file, usize::MAX).unwrap();
    assert_eq!(turns.len(), 3);
    let total = turns
        .iter()
        .map(|turn| crate::wire::json::encoded_len(turn).unwrap())
        .sum::<usize>();

    assert_eq!(projection.thread_turns(&file, total).unwrap(), turns);
    match projection.thread_turns(&file, total - 1) {
        Err(HistoryError::Capacity(capacity)) => assert_eq!(capacity.limit, total - 1),
        other => panic!("expected a capacity error, got {other:?}"),
    }
}

#[test]
fn thread_turns_stop_at_the_first_item_past_the_budget_without_reading_later_records() {
    use std::os::unix::fs::FileExt;

    let home = TempDir::new().unwrap();
    let path = write_session(home.path(), CWD, "early", &three_turns());
    let (projection, file) = project(home.path(), "claude_early", &path, None);
    let first_turn_items = projection.thread_turns(&file, usize::MAX).unwrap()[0]["items"].clone();
    assert_eq!(first_turn_items[2]["id"], "m1#1");
    let first_item_bytes = crate::wire::json::encoded_len(&first_turn_items[0]).unwrap();

    let transcript = fs::read_to_string(&path).unwrap();
    let last_item_record = transcript
        .lines()
        .find(|line| line.contains(r#""uuid":"a2""#))
        .unwrap();
    let offset = transcript.find(last_item_record).unwrap() as u64;
    fs::OpenOptions::new()
        .write(true)
        .open(&path)
        .unwrap()
        .write_all_at(" ".repeat(last_item_record.len()).as_bytes(), offset)
        .unwrap();

    assert!(matches!(
        projection.thread_turns(&file, usize::MAX),
        Err(HistoryError::Internal(_))
    ));
    match projection.thread_turns(&file, first_item_bytes) {
        Err(HistoryError::Capacity(capacity)) => assert_eq!(capacity.limit, first_item_bytes),
        other => panic!("expected a capacity error before the unreadable record, got {other:?}"),
    }
}

#[test]
fn the_record_reader_keeps_its_decoded_records_within_its_byte_budget() {
    let home = TempDir::new().unwrap();
    let half = RECORD_CACHE_BUDGET_BYTES / 2;
    let records = [
        json!({"text": "a".repeat(half)}),
        json!({"text": "b".repeat(half)}),
    ];
    let path = write_session(home.path(), CWD, "records", &records);
    let file = File::open(&path).unwrap();
    let first = Span {
        offset: 0,
        len: records[0].to_string().len(),
    };
    let second = Span {
        offset: first.len as u64 + 1,
        len: records[1].to_string().len(),
    };
    let mut reader = RecordReader::new(&file);

    assert_eq!(reader.read(first).unwrap(), &records[0]);
    assert_eq!(reader.read(second).unwrap(), &records[1]);
    assert_eq!(reader.records.len(), 1);
    assert_eq!(reader.cached_bytes, second.len);
    assert_eq!(reader.read(first).unwrap(), &records[0]);
    assert!(reader.cached_bytes <= RECORD_CACHE_BUDGET_BYTES);
}

#[test]
fn page_defaults_and_limits_follow_the_codex_contract() {
    let home = TempDir::new().unwrap();
    let path = write_session(home.path(), CWD, "defaults", &three_turns());
    let thread = "claude_defaults";
    let (projection, file) = project(home.path(), thread, &path, None);

    let first = projection
        .items_page(&file, &items_params(thread, None, None, None, None))
        .unwrap();
    assert_eq!(ids(first["data"].as_array().unwrap())[0], "P1");
    assert_eq!(first["nextCursor"], Value::Null);
    assert!(first["backwardsCursor"].is_string());

    let one = projection
        .items_page(
            &file,
            &items_params(thread, None, None, Some(0), Some(SortDirection::Desc)),
        )
        .unwrap();
    assert_eq!(ids(one["data"].as_array().unwrap()), ["m3#2"]);
    assert!(one["nextCursor"].is_string());
    let all = projection
        .items_page(&file, &items_params(thread, None, None, Some(1000), None))
        .unwrap();
    assert_eq!(all["data"].as_array().unwrap().len(), 9);
    assert_eq!(all["nextCursor"], Value::Null);

    let backwards = projection
        .items_page(
            &file,
            &items_params(
                thread,
                None,
                one["backwardsCursor"].as_str().map(str::to_string),
                Some(2),
                Some(SortDirection::Asc),
            ),
        )
        .unwrap();
    assert_eq!(ids(backwards["data"].as_array().unwrap()), ["m3#2"]);

    let turns = projection
        .turns_page(&file, &turns_params(thread, None, Some(2), None))
        .unwrap();
    let data = turns["data"].as_array().unwrap();
    assert_eq!(data[0]["id"], "claude-turn-3");
    assert_eq!(data[0]["itemsView"], "summary");
    assert_eq!(
        data[0]["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["P3", "m3#2"]
    );
    assert_eq!(data[0]["startedAt"], 1_786_887_320i64);
    assert_eq!(data[0]["durationMs"], 5_000);
    let rest = projection
        .turns_page(
            &file,
            &turns_params(
                thread,
                turns["nextCursor"].as_str().map(str::to_string),
                Some(2),
                Some(ItemsView::NotLoaded),
            ),
        )
        .unwrap();
    assert_eq!(rest["data"][0]["id"], "claude-turn-1");
    assert_eq!(rest["data"][0]["itemsView"], "notLoaded");
    assert_eq!(rest["data"][0]["items"], json!([]));
    assert_eq!(rest["nextCursor"], Value::Null);

    let empty_home = TempDir::new().unwrap();
    let empty = write_session(empty_home.path(), CWD, "empty", &[]);
    let (projection, file) = project(empty_home.path(), "claude_empty", &empty, None);
    assert_eq!(
        projection
            .turns_page(
                &file,
                &turns_params("claude_empty", Some("garbage".into()), None, None)
            )
            .unwrap(),
        json!({"data": [], "nextCursor": null, "backwardsCursor": null})
    );
}

#[test]
fn a_cursor_that_no_longer_resolves_is_an_invalid_request() {
    let home = TempDir::new().unwrap();
    let path = write_session(home.path(), CWD, "cursor", &three_turns());
    let thread = "claude_cursor";
    let (projection, file) = project(home.path(), thread, &path, None);
    let page = projection
        .items_page(
            &file,
            &items_params(thread, None, None, Some(1), Some(SortDirection::Desc)),
        )
        .unwrap();
    let cursor = page["nextCursor"].as_str().unwrap().to_string();

    assert_eq!(
        invalid_request(projection.items_page(
            &file,
            &items_params(
                thread,
                Some("claude-turn-1"),
                Some(cursor.clone()),
                None,
                None
            ),
        )),
        "invalid cursor: anchor item is no longer present"
    );
    assert_eq!(
        invalid_request(projection.items_page(
            &file,
            &items_params("claude_other", None, Some(cursor.clone()), None, None),
        )),
        format!("invalid cursor: {cursor}")
    );
    assert_eq!(
        invalid_request(projection.items_page(
            &file,
            &items_params(thread, None, Some("garbage".into()), None, None)
        )),
        "invalid cursor: garbage"
    );

    let mut rewritten = three_turns();
    rewritten.truncate(11);
    rewritten.push(json!({"type":"assistant","uuid":"a7","timestamp":"2026-08-16T13:35:26.000Z","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"rewritten"}]}}));
    write_session(home.path(), CWD, "cursor", &rewritten);
    let (projection, file) = project(home.path(), thread, &path, None);
    assert_eq!(
        invalid_request(
            projection.items_page(&file, &items_params(thread, None, Some(cursor), None, None))
        ),
        "invalid cursor: anchor item is no longer present"
    );
    let turn_cursor =
        serde_json::to_string(&json!({"turnId":"claude-turn-9","includeAnchor":false})).unwrap();
    assert_eq!(
        invalid_request(
            projection.turns_page(&file, &turns_params(thread, Some(turn_cursor), None, None))
        ),
        "invalid cursor: anchor turn is no longer present"
    );
}

#[tokio::test]
async fn the_cache_rebuilds_on_every_input_change_and_serves_unchanged_reads() {
    let home = TempDir::new().unwrap();
    let thread = "claude_cached";
    let path = write_session(home.path(), CWD, "cached", &three_turns());
    let cache = ProjectionCache::new(PROJECTION_CACHE_BUDGET_BYTES);
    let read = |active: Option<&str>| {
        cache
            .read(home.path(), thread, &path, active, |projection, file| {
                let page = projection.items_page(
                    file,
                    &items_params(thread, None, None, Some(100), Some(SortDirection::Desc)),
                )?;
                Ok(ids(page["data"].as_array().unwrap()))
            })
            .unwrap()
    };

    let (first, outcome) = read(None);
    assert_eq!(outcome, CacheOutcome::Built);
    assert_eq!(first.len(), 9);
    assert_eq!(read(None).1, CacheOutcome::Hit);

    append(
        &path,
        &json!({"type":"assistant","uuid":"a7","timestamp":"2026-08-16T13:35:26.000Z","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"more"}]}}),
    );
    let (grown, outcome) = read(None);
    assert_eq!(outcome, CacheOutcome::Built);
    assert_eq!(grown[0], "m4#0");

    let original = fs::read(&path).unwrap();
    let replacement = path.with_extension("tmp");
    fs::write(
        &replacement,
        String::from_utf8(original.clone())
            .unwrap()
            .replacen("\"more\"", "\"MORE\"", 1),
    )
    .unwrap();
    fs::rename(&replacement, &path).unwrap();
    assert_eq!(fs::metadata(&path).unwrap().len(), original.len() as u64);
    let (rewritten, outcome) = cache
        .read(home.path(), thread, &path, None, |projection, file| {
            projection.items_page(
                file,
                &items_params(thread, None, None, Some(1), Some(SortDirection::Desc)),
            )
        })
        .unwrap();
    assert_eq!(outcome, CacheOutcome::Built);
    assert_eq!(rewritten["data"][0]["item"]["text"], "MORE");

    assert_eq!(read(Some("claude-turn-live")).1, CacheOutcome::Built);
    assert_eq!(read(Some("claude-turn-live")).1, CacheOutcome::Hit);

    let store = Store::new(home.path().to_path_buf());
    store
        .record(&mut json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":"claude-turn-live","startedAtMs":1000,"status":"inProgress"}}}))
        .await
        .unwrap();
    assert_eq!(read(Some("claude-turn-live")).1, CacheOutcome::Built);
}

#[test]
fn the_cache_evicts_the_least_recently_used_projection_and_never_holds_one_over_budget() {
    let home = TempDir::new().unwrap();
    let small = write_session(home.path(), CWD, "small", &three_turns()[..4]);
    let large = write_session(home.path(), CWD, "large", &three_turns());
    let bytes =
        |thread: &str, path: &Path| project(home.path(), thread, path, None).0.estimated_bytes();
    let (small_bytes, large_bytes) = (bytes("claude_small", &small), bytes("claude_large", &large));
    assert!(small_bytes < large_bytes);

    let cache = ProjectionCache::new(large_bytes + small_bytes - 1);
    let read = |thread: &str, path: &Path| {
        cache
            .read(home.path(), thread, path, None, |_, _| Ok(()))
            .unwrap()
            .1
    };
    assert_eq!(read("claude_small", &small), CacheOutcome::Built);
    assert_eq!(read("claude_small", &small), CacheOutcome::Hit);
    assert_eq!(read("claude_large", &large), CacheOutcome::Built);
    assert_eq!(read("claude_large", &large), CacheOutcome::Hit);
    assert_eq!(read("claude_small", &small), CacheOutcome::Built);
    assert_eq!(read("claude_large", &large), CacheOutcome::Built);

    let tiny = ProjectionCache::new(small_bytes - 1);
    let (entries, outcome) = tiny
        .read(
            home.path(),
            "claude_small",
            &small,
            None,
            |projection, file| {
                projection.items_page(file, &items_params("claude_small", None, None, None, None))
            },
        )
        .unwrap();
    assert_eq!(outcome, CacheOutcome::Uncached);
    assert_eq!(entries["data"].as_array().unwrap().len(), 3);
    assert_eq!(
        tiny.read(home.path(), "claude_small", &small, None, |_, _| Ok(()))
            .unwrap()
            .1,
        CacheOutcome::Uncached
    );
}

fn session_with_usage() -> Vec<Value> {
    vec![
        json!({"type":"user","uuid":"U1","cwd":CWD,"timestamp":"2026-08-16T13:35:17.605Z","message":{"role":"user","content":"hello"}}),
        json!({"type":"assistant","uuid":"a1","timestamp":"2026-08-16T13:35:18.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"first"}],
            "usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":2}}}),
        json!({"type":"assistant","uuid":"a2","timestamp":"2026-08-16T13:35:20.000Z","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"second"}],
            "usage":{"input_tokens":2,"cache_read_input_tokens":109_494,"cache_creation_input_tokens":2_743,"output_tokens":583,"output_tokens_details":{"thinking_tokens":108}}}}),
        json!({"type":"user","uuid":"U2","timestamp":"2026-08-16T13:36:00.000Z","message":{"role":"user","content":"next"}}),
    ]
}

#[test]
fn the_token_usage_replay_is_the_newest_request_attributed_to_its_turn() {
    let claude_test = ClaudeSettings::isolated_for_test();
    let home = claude_test.settings.claude_home.as_path();
    let path = write_session(home, CWD, "usage", &session_with_usage());
    fs::write(
        home.join("settings.json"),
        r#"{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"400000"}}"#,
    )
    .unwrap();
    let (projection, _) = project(home, "claude_usage", &path, Some("claude-turn-live"));

    let replay = projection
        .token_usage_replay("claude_usage", &claude_test.settings)
        .unwrap();
    assert_eq!(replay["method"], "thread/tokenUsage/updated");
    assert_eq!(replay["params"]["threadId"], "claude_usage");
    assert_eq!(replay["params"]["turnId"], "claude-turn-1");
    let usage = &replay["params"]["tokenUsage"];
    assert_eq!(usage["total"]["totalTokens"], 112_822);
    assert_eq!(usage["total"]["inputTokens"], 2);
    assert_eq!(usage["total"]["cachedInputTokens"], 109_494);
    assert_eq!(usage["total"]["outputTokens"], 583);
    assert_eq!(usage["total"]["reasoningOutputTokens"], 108);
    assert_eq!(usage["last"], usage["total"]);
    assert_eq!(usage["modelContextWindow"], 400_000);

    fs::remove_file(home.join("settings.json")).unwrap();
    let replay = projection
        .token_usage_replay("claude_usage", &claude_test.settings)
        .unwrap();
    assert_eq!(
        replay["params"]["tokenUsage"]["modelContextWindow"],
        Value::Null
    );

    let quiet = write_session(home, CWD, "quiet", &session_with_usage()[..1]);
    let (projection, _) = project(home, "claude_quiet", &quiet, None);
    assert!(
        projection
            .token_usage_replay("claude_quiet", &claude_test.settings)
            .is_none()
    );
}

#[test]
fn usage_without_a_projected_turn_does_not_invent_a_turn_id() {
    let claude_test = ClaudeSettings::isolated_for_test();
    let home = claude_test.settings.claude_home.as_path();
    let path = write_session(
        home,
        CWD,
        "usage-only",
        &[json!({"type":"assistant","message":{"content":[],"usage":{"input_tokens":3}}})],
    );
    let (projection, _) = project(home, "claude_usage-only", &path, None);

    assert!(projection.turns.is_empty());
    assert!(
        projection
            .token_usage_replay("claude_usage-only", &claude_test.settings)
            .is_none()
    );
}

fn sample_session() -> Vec<Value> {
    vec![
        json!({"type":"queue-operation","sessionId":"s1"}),
        json!({"type":"user","uuid":"U1","cwd":CWD,"isSidechain":false,"timestamp":"2026-08-16T13:35:17.605Z","message":{"role":"user","content":"Run the bash command: echo hello."}}),
        json!({"type":"ai-title","aiTitle":"Run echo hello command","sessionId":"s1"}),
        json!({"type":"assistant","uuid":"a1","cwd":CWD,"isSidechain":false,"timestamp":"2026-08-16T13:35:20.217Z","message":{"id":"m1","role":"assistant","content":[
            {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hello"}}]}}),
        json!({"type":"user","uuid":"r1","cwd":CWD,"isSidechain":false,"timestamp":"2026-08-16T13:35:20.395Z","message":{"role":"user","content":[
            {"type":"tool_result","tool_use_id":"toolu_1","content":"hello","is_error":false}]},
            "toolUseResult":{"stdout":"hello","stderr":"","interrupted":false}}),
        json!({"type":"assistant","uuid":"a2","cwd":CWD,"isSidechain":false,"timestamp":"2026-08-16T13:35:21.575Z","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"done"}]}}),
        json!({"type":"assistant","uuid":"a3","cwd":CWD,"isSidechain":true,"timestamp":"2026-08-16T13:35:21.600Z","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"inner"}]}}),
    ]
}

fn all_entries(home: &Path, uuid: &str, records: &[Value], active: Option<&str>) -> Vec<Value> {
    let path = write_session(home, CWD, uuid, records);
    let thread = format!("claude_{uuid}");
    let (projection, file) = project(home, &thread, &path, active);
    walk(&projection, &file, &thread, None, 100, SortDirection::Asc)
}

fn all_turns(home: &Path, uuid: &str, active: Option<&str>) -> Vec<Value> {
    let thread = format!("claude_{uuid}");
    let path = crate::providers::claude::timeline::resolve_session_path(uuid, home).unwrap();
    let (projection, file) = project(home, &thread, &path, active);
    projection
        .turns_page(
            &file,
            &turns_params(&thread, None, Some(100), Some(ItemsView::Full)),
        )
        .unwrap()["data"]
        .as_array()
        .unwrap()
        .clone()
}

#[test]
fn history_reconstructs_prompts_replies_and_finished_tools_without_sidechains() {
    let home = TempDir::new().unwrap();
    let entries = all_entries(home.path(), "sample", &sample_session(), None);
    assert_eq!(ids(&entries), ["U1", "toolu_1", "m2#0"]);
    assert_eq!(
        texts(&entries),
        ["Run the bash command: echo hello.", "done"]
    );
    assert!(
        entries
            .iter()
            .all(|entry| entry["turnId"] == "claude-turn-1")
    );
    assert!(
        entries
            .iter()
            .all(|entry| entry.get("startedAtOrdinal").is_none())
    );
    let tool = &entries[1];
    assert_eq!(tool["isComplete"], true);
    assert_eq!(tool["startedAtMs"], 1_786_887_320_217i64);
    assert_eq!(tool["completedAtMs"], 1_786_887_320_395i64);
    assert_eq!(tool["item"]["durationMs"], 178);
    assert!(tool["item"].to_string().contains("hello"));
    assert_eq!(entries[0]["item"]["clientId"], "U1");

    let turns = all_turns(home.path(), "sample", None);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0]["status"], "completed");
    assert_eq!(turns[0]["completedAt"], 1_786_887_321i64);
    assert_eq!(turns[0]["error"], Value::Null);
}

#[test]
fn a_sent_message_replays_as_the_verbatim_agent_message_the_stream_showed() {
    let home = TempDir::new().unwrap();
    let message = "```sh\nprintf 'a\\nb\\n' | sort -r\n```\n\nSorts in reverse.";
    let mut session = sample_session();
    session.splice(
        5..5,
        [
            json!({"type":"assistant","uuid":"a1s","cwd":CWD,"isSidechain":false,"timestamp":"2026-08-16T13:35:20.500Z","message":{"id":"m1s","role":"assistant","content":[
                {"type":"tool_use","id":"toolu_send","name":"SendUserMessage","input":{"message":message}}]}}),
            json!({"type":"user","uuid":"r1s","cwd":CWD,"isSidechain":false,"timestamp":"2026-08-16T13:35:20.600Z","message":{"role":"user","content":[
                {"type":"tool_result","tool_use_id":"toolu_send","content":"Message delivered to user."}]}}),
        ],
    );

    let entries = all_entries(home.path(), "sent", &session, None);

    assert_eq!(ids(&entries), ["U1", "toolu_1", "toolu_send", "m2#0"]);
    assert_eq!(entries[2]["item"]["type"], "agentMessage");
    assert_eq!(entries[2]["item"]["text"], message);
}

#[test]
fn a_running_turn_is_never_reported_completed() {
    let home = TempDir::new().unwrap();
    let mut records = sample_session();
    records.truncate(5);
    let entries = all_entries(home.path(), "live", &records, Some("claude-turn-live"));
    assert!(
        entries
            .iter()
            .all(|entry| entry["turnId"] == "claude-turn-live")
    );
    let turns = all_turns(home.path(), "live", Some("claude-turn-live"));
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0]["status"], "inProgress");
    assert_eq!(turns[0]["completedAt"], Value::Null);
    assert_eq!(turns[0]["durationMs"], Value::Null);
}

#[test]
fn an_unfinished_tool_is_incomplete_and_the_active_turn_exists_before_its_prompt_is_written() {
    let home = TempDir::new().unwrap();
    let mut records = sample_session();
    records.truncate(4);
    let entries = all_entries(home.path(), "pending", &records, None);
    assert_eq!(entries[1]["item"]["id"], "toolu_1");
    assert_eq!(entries[1]["isComplete"], false);
    assert!(entries[1].get("completedAtMs").is_none());

    let turns = all_turns(home.path(), "pending", None);
    assert_eq!(turns.len(), 1);
    let empty = write_session(home.path(), CWD, "fresh", &[]);
    let (projection, file) = project(home.path(), "claude_fresh", &empty, Some("claude-turn-new"));
    let page = projection
        .turns_page(&file, &turns_params("claude_fresh", None, None, None))
        .unwrap();
    assert_eq!(page["data"][0]["id"], "claude-turn-new");
    assert_eq!(page["data"][0]["status"], "inProgress");
}

#[test]
fn the_notification_permit_never_reaches_history() {
    let home = TempDir::new().unwrap();
    let mut records = sample_session();
    records[3]["message"]["content"][0] = json!({
        "type":"tool_use","id":"toolu_1","name":crate::providers::claude::notification_hook::TOOL,
        "input":{"title":"Fixture","body":"Root",crate::agents::mcp::NOTIFICATION_PERMIT_FIELD:"retained-native-proof"}
    });
    let entries = all_entries(home.path(), "proof", &records, None);
    let projected = serde_json::to_string(&entries).unwrap();
    assert!(!projected.contains("retained-native-proof"));
    assert!(!projected.contains(crate::agents::mcp::NOTIFICATION_PERMIT_FIELD));
    let item = &entries[1]["item"];
    assert_eq!(item["type"], "mcpToolCall");
    assert_eq!(item["server"], "remotecoder");
    assert_eq!(item["tool"], "notify_user");
}

#[test]
fn injected_records_never_open_turns_or_become_user_messages() {
    let home = TempDir::new().unwrap();
    let mut records = sample_session();
    records.extend([
        json!({"type":"user","uuid":"i1","cwd":CWD,"isMeta":true,"timestamp":"2026-08-16T13:35:22.000Z","message":{"role":"user","content":"Base directory for this skill: /Users/developer/.claude/skills/github"}}),
        json!({"type":"user","uuid":"i2","cwd":CWD,"timestamp":"2026-08-16T13:35:23.000Z","message":{"role":"user","content":[{"type":"text","text":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>"}]}}),
        json!({"type":"user","uuid":"i3","cwd":CWD,"timestamp":"2026-08-16T13:35:24.000Z","message":{"role":"user","content":"<command-name>/compact</command-name>"}}),
        json!({"type":"user","uuid":"i4","cwd":CWD,"timestamp":"2026-08-16T13:35:25.000Z","message":{"role":"user","content":"<local-command-stdout>Compacted</local-command-stdout>"}}),
        json!({"type":"user","uuid":"i5","cwd":CWD,"timestamp":"2026-08-16T13:35:25.500Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}),
        json!({"type":"assistant","uuid":"a4","cwd":CWD,"timestamp":"2026-08-16T13:35:26.000Z","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"the background task finished"}]}}),
    ]);
    let entries = all_entries(home.path(), "injected", &records, None);
    assert_eq!(
        texts(&entries),
        [
            "Run the bash command: echo hello.",
            "done",
            "the background task finished"
        ]
    );
    assert_eq!(all_turns(home.path(), "injected", None).len(), 1);
}

#[test]
fn a_compaction_preamble_opens_a_turn_without_a_user_message() {
    let home = TempDir::new().unwrap();
    let records = [
        json!({"type":"user","uuid":"c1","cwd":CWD,"isCompactSummary":true,"timestamp":"2026-08-16T13:35:17.605Z","message":{"role":"user","content":"This session is being continued from a previous conversation…"}}),
        json!({"type":"assistant","uuid":"a1","cwd":CWD,"timestamp":"2026-08-16T13:35:19.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"picking the work back up"}]}}),
    ];
    let entries = all_entries(home.path(), "compact", &records, None);
    assert_eq!(ids(&entries), ["m1#0"]);
    assert_eq!(texts(&entries), ["picking the work back up"]);
}

#[tokio::test]
async fn provider_file_preserves_stream_block_identity_and_a_tool_finishing_after_steering() {
    let home = TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let thread = "claude_fixture";
    let turn = "claude-turn-live";
    let frame = |method: &str, item: Value| json!({"method":method,"params":{"threadId":thread,"turnId":turn,"item":item,"startedAtMs":1000,"completedAtMs":2000}});
    for mut frame in [
        frame(
            "item/completed",
            json!({"type":"userMessage","id":"user","clientId":"user","content":[]}),
        ),
        frame(
            "item/started",
            json!({"type":"commandExecution","id":"tool"}),
        ),
        frame(
            "item/completed",
            json!({"type":"agentMessage","id":"msg#1","text":"Progress"}),
        ),
        frame(
            "item/completed",
            json!({"type":"userMessage","id":"steer","clientId":"steer","content":[]}),
        ),
        frame(
            "item/completed",
            json!({"type":"commandExecution","id":"tool"}),
        ),
    ] {
        store.record(&mut frame).await.unwrap();
    }
    let records = [
        json!({"type":"user","uuid":"user","cwd":CWD,"timestamp":"2026-09-10T12:00:00Z","message":{"role":"user","content":"Start"}}),
        json!({"type":"assistant","uuid":"a1","timestamp":"2026-09-10T12:00:01Z","message":{"id":"msg","role":"assistant","content":[{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"long task"}}]}}),
        json!({"type":"assistant","uuid":"a2","timestamp":"2026-09-10T12:00:02Z","message":{"id":"msg","role":"assistant","content":[{"type":"text","text":"Progress"}]}}),
        json!({"type":"assistant","uuid":"a2","timestamp":"2026-09-10T12:00:02Z","message":{"id":"msg","role":"assistant","content":[{"type":"text","text":"Progress"}]}}),
        json!({"type":"user","uuid":"steer","timestamp":"2026-09-10T12:00:03Z","message":{"role":"user","content":"Also this"}}),
        json!({"type":"user","uuid":"result","timestamp":"2026-09-10T12:00:04Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool","content":"Finished after steering"}]}}),
    ];
    let entries = all_entries(home.path(), "fixture", &records, None);
    assert_eq!(ids(&entries), ["user", "tool", "msg#1", "steer"]);
    assert_eq!(
        entries
            .iter()
            .map(|entry| entry["startedAtOrdinal"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        [0, 1, 2, 3]
    );
    assert!(entries.iter().all(|entry| entry["turnId"] == turn));
    assert_eq!(entries[1]["isComplete"], true);
    assert!(
        entries[1]["item"]
            .to_string()
            .contains("Finished after steering")
    );
    let turns = all_turns(home.path(), "fixture", None);
    assert_eq!(turns.len(), 1);
}

#[tokio::test]
async fn a_prompt_the_stream_has_not_echoed_joins_the_running_turn_with_its_client_identity() {
    let home = TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let thread = "claude_unechoed";
    let settled_turn = "claude-turn-1789856900000-25";
    let running_turn = "claude-turn-1789856966285-26";
    let client_id = "56E73CB1-566E-4444-B003-C9DC40FFF3E3";
    let frame = |turn: &str, item: Value| json!({"method":"item/completed","params":{"threadId":thread,"turnId":turn,"item":item,"startedAtMs":1000,"completedAtMs":2000}});
    for mut frame in [
        json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":settled_turn,"startedAtMs":1_789_856_900_000i64,"status":"inProgress"}}}),
        frame(
            settled_turn,
            json!({"type":"userMessage","id":"SETTLED","clientId":"SETTLED","content":[]}),
        ),
        frame(
            settled_turn,
            json!({"type":"agentMessage","id":"msg#0","text":"Done"}),
        ),
        json!({"method":"turn/completed","params":{"threadId":thread,"turn":{"id":settled_turn,"completedAtMs":1_789_856_929_377i64,"status":"completed"}}}),
        json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":running_turn,"startedAtMs":1_789_856_966_285i64,"status":"inProgress"}}}),
    ] {
        store.record(&mut frame).await.unwrap();
    }
    let records = [
        json!({"type":"user","uuid":"SETTLED","cwd":CWD,"timestamp":"2026-09-19T22:28:20Z","message":{"role":"user","content":"Mute the tint"}}),
        json!({"type":"assistant","uuid":"a1","timestamp":"2026-09-19T22:29:09Z","message":{"id":"msg","role":"assistant","content":[{"type":"text","text":"Done"}]}}),
        json!({"type":"user","uuid":client_id,"timestamp":"2026-09-19T22:29:26Z","message":{"role":"user","content":"great also a biiit less toward black/white"}}),
    ];

    let entries = all_entries(home.path(), "unechoed", &records, Some(running_turn));
    assert_eq!(entries[2]["turnId"], running_turn);
    assert_eq!(entries[2]["item"]["id"], client_id);
    assert_eq!(entries[2]["item"]["clientId"], client_id);
    let turns = all_turns(home.path(), "unechoed", Some(running_turn));
    assert_eq!(turns.len(), 2, "unexpected grouping: {turns:#?}");
    assert_eq!(turns[0]["id"], running_turn);
    assert_eq!(turns[0]["status"], "inProgress");
    assert_eq!(turns[0]["startedAt"], 1_789_856_966i64);
    assert_eq!(turns[1]["id"], settled_turn);
    assert_eq!(turns[1]["status"], "completed");

    let external = all_turns(home.path(), "unechoed", None);
    assert_eq!(external[0]["id"], "claude-turn-2");
    assert_eq!(external[0]["status"], "completed");
    assert_eq!(external[1]["id"], settled_turn);
}

#[tokio::test]
async fn an_indexed_turn_left_running_by_a_dead_gateway_reads_as_interrupted() {
    let home = TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let thread = "claude_orphan";
    for mut frame in [
        json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":"claude-turn-orphan","startedAtMs":1_786_887_317_000i64,"status":"inProgress"}}}),
        json!({"method":"item/completed","params":{"threadId":thread,"turnId":"claude-turn-orphan","item":{"type":"userMessage","id":"U1","clientId":"U1","content":[]},"startedAtMs":1000,"completedAtMs":2000}}),
    ] {
        store.record(&mut frame).await.unwrap();
    }
    let mut records = sample_session();
    records.truncate(4);
    write_session(home.path(), CWD, "orphan", &records);
    let turns = all_turns(home.path(), "orphan", None);
    assert_eq!(turns[0]["id"], "claude-turn-orphan");
    assert_eq!(turns[0]["status"], "interrupted");
    assert_eq!(
        all_turns(home.path(), "orphan", Some("claude-turn-orphan"))[0]["status"],
        "inProgress"
    );
}

#[tokio::test]
async fn restart_recoveries_keep_their_order_and_their_steers() {
    let home = TempDir::new().unwrap();
    let store = Store::new(home.path().to_path_buf());
    let thread = "claude_restarted";
    let interrupted = "claude-turn-1790200612990-23";
    let empty_resume = "claude-turn-1790201597802-3";
    let first_recovery = "claude-turn-1790201604265-4";
    let second_recovery = "claude-turn-1790202564261-5";
    let typed = "claude-turn-1790203057267-13";

    let started = |turn: &str, ms: i64| json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":turn,"startedAtMs":ms,"status":"inProgress"}}});
    let completed = |turn: &str, ms: i64| json!({"method":"turn/completed","params":{"threadId":thread,"turn":{"id":turn,"completedAtMs":ms,"status":"completed"}}});
    let item = |turn: &str, item: Value| json!({"method":"item/completed","params":{"threadId":thread,"turnId":turn,"item":item,"startedAtMs":1000,"completedAtMs":2000}});
    let user = |turn: &str, id: &str| {
        item(
            turn,
            json!({"type":"userMessage","id":id,"clientId":id,"content":[]}),
        )
    };
    let reply = |turn: &str, id: &str| {
        item(
            turn,
            json!({"type":"agentMessage","id":format!("{id}#0"),"text":id}),
        )
    };
    for frame in &mut [
        started(interrupted, 1_000),
        user(interrupted, "PROMPT"),
        reply(interrupted, "m1"),
        completed(interrupted, 2_000),
        started(empty_resume, 3_000),
        completed(empty_resume, 3_100),
        started(first_recovery, 3_200),
        reply(first_recovery, "m2"),
        user(first_recovery, "STEER-1"),
        reply(first_recovery, "m3"),
        completed(first_recovery, 4_000),
        started(second_recovery, 5_000),
        reply(second_recovery, "m4"),
        user(second_recovery, "STEER-2"),
        reply(second_recovery, "m5"),
    ] {
        store.record(frame).await.unwrap();
    }

    let assistant = |id: &str, text: &str| json!({"type":"assistant","uuid":format!("a-{id}"),"message":{"id":id,"role":"assistant","content":[{"type":"text","text":text}]}});
    let resume_nudge = |n: u8| {
        [
            json!({"type":"user","uuid":format!("nudge-{n}"),"isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]}}),
            json!({"type":"assistant","uuid":format!("synthetic-{n}"),"message":{"id":format!("synthetic-{n}"),"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}]}}),
            json!({"type":"user","uuid":format!("notice-{n}"),"isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"The RemoteCoder gateway restarted."}]}}),
        ]
    };
    let queued = |id: &str, text: &str, meta: bool| {
        let mut attachment =
            json!({"type":"queued_command","prompt":text,"source_uuid":id,"commandMode":"prompt"});
        if meta {
            attachment["isMeta"] = json!(true);
        }
        json!({"type":"attachment","uuid":format!("att-{id}"),"attachment":attachment})
    };
    let mut records = vec![
        json!({"type":"user","uuid":"PROMPT","cwd":CWD,"message":{"role":"user","content":"Build the board"}}),
        assistant("m1", "Working"),
    ];
    records.extend(resume_nudge(1));
    records.extend([
        assistant("m2", "Resuming"),
        queued("STEER-1", "Also polish mobile", false),
        queued(
            "AGENT",
            "<agent_message id=\"x\">peer</agent_message>",
            true,
        ),
        assistant("m3", "Polished"),
    ]);
    records.extend(resume_nudge(2));
    records.extend([
        assistant("m4", "Resuming again"),
        queued("STEER-2", "And the fonts", false),
        assistant("m5", "Fonts done"),
    ]);
    let read = |records: &[Value], active: Option<&str>| {
        let entries = all_entries(home.path(), "restarted", records, active);
        let mut turns: Vec<(String, Vec<String>, Vec<String>)> = Vec::new();
        for entry in &entries {
            let turn_id = entry["turnId"].as_str().unwrap().to_string();
            if turns.last().is_none_or(|(last, _, _)| *last != turn_id) {
                turns.push((turn_id, Vec::new(), Vec::new()));
            }
            let (_, texts_in_turn, clients) = turns.last_mut().unwrap();
            texts_in_turn.extend(texts(std::slice::from_ref(entry)));
            if entry["item"]["type"] == "userMessage" {
                clients.push(entry["item"]["clientId"].as_str().unwrap().to_string());
            }
        }
        turns
    };
    let expected = |rows: &[(&str, &[&str], &[&str])]| {
        rows.iter()
            .map(|(id, texts, clients)| {
                (
                    id.to_string(),
                    texts
                        .iter()
                        .map(|text| text.to_string())
                        .collect::<Vec<_>>(),
                    clients
                        .iter()
                        .map(|client| client.to_string())
                        .collect::<Vec<_>>(),
                )
            })
            .collect::<Vec<_>>()
    };
    let recoveries: [(&str, &[&str], &[&str]); 3] = [
        (interrupted, &["Build the board", "Working"], &["PROMPT"]),
        (
            first_recovery,
            &["Resuming", "Also polish mobile", "Polished"],
            &["STEER-1"],
        ),
        (
            second_recovery,
            &["Resuming again", "And the fonts", "Fonts done"],
            &["STEER-2"],
        ),
    ];
    assert_eq!(read(&records, Some(second_recovery)), expected(&recoveries));

    for frame in &mut [
        completed(second_recovery, 6_000),
        started(typed, 7_000),
        user(typed, "HELLO"),
        reply(typed, "m6"),
    ] {
        store.record(frame).await.unwrap();
    }
    records.extend([
        json!({"type":"user","uuid":"HELLO","message":{"role":"user","content":"hello"}}),
        assistant("m6", "Hi"),
    ]);
    let mut all = recoveries.to_vec();
    all.push((typed, &["hello", "Hi"], &["HELLO"]));
    assert_eq!(read(&records, None), expected(&all));
}

fn record_bytes(records: &[Value]) -> u64 {
    records
        .iter()
        .map(|record| format!("{record}\n").len() as u64)
        .sum()
}

async fn index_turn(store: &Store, thread: &str, turn: &str, items: Vec<Value>) {
    let mut frames = vec![
        json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":turn,"startedAtMs":1,"status":"inProgress"}}}),
    ];
    frames.extend(items.into_iter().map(|item| {
        json!({"method":"item/completed","params":{"threadId":thread,"turnId":turn,"item":item,"startedAtMs":1,"completedAtMs":1}})
    }));
    frames.push(json!({"method":"turn/completed","params":{"threadId":thread,"turn":{"id":turn,"startedAtMs":1,"completedAtMs":2,"status":"completed"}}}));
    for frame in &mut frames {
        store.record(frame).await.unwrap();
    }
}

async fn index_drafts(home: &Path, uuid: &str, records: &[Value], turns: &[&str]) -> Store {
    let thread = format!("claude_{uuid}");
    let entries = all_entries(home, uuid, records, None);
    let store = Store::new(home.to_path_buf());
    for (position, turn) in turns.iter().enumerate() {
        let draft = format!("claude-turn-{}", position + 1);
        let items = entries
            .iter()
            .filter(|entry| entry["turnId"] == draft.as_str())
            .map(|entry| json!({"type":"agentMessage","id":entry["item"]["id"]}))
            .collect();
        index_turn(&store, &thread, turn, items).await;
    }
    store
}

fn turn_set(turns: &[&str]) -> HashSet<String> {
    turns.iter().map(|turn| turn.to_string()).collect()
}

#[test]
fn a_fork_point_keeps_the_result_of_its_last_tool() {
    let home = TempDir::new().unwrap();
    let mut records = three_turns();
    records.remove(3);
    let path = write_session(home.path(), CWD, "tool", &records);
    let (projection, _) = project(home.path(), "claude_tool", &path, None);

    let point = projection.fork_point(Some("claude-turn-1")).unwrap();

    assert_eq!(point.length, record_bytes(&records[..3]));
    assert_eq!(point.turns, turn_set(&["claude-turn-1"]));
}

#[test]
fn a_turn_that_a_later_prompt_interleaves_is_not_a_fork_point() {
    let home = TempDir::new().unwrap();
    let turns = three_turns();
    let records = [0, 1, 4, 2, 5].map(|position| turns[position].clone());
    let path = write_session(home.path(), CWD, "interleaved", &records);
    let (projection, _) = project(home.path(), "claude_interleaved", &path, None);

    assert!(matches!(
        projection.fork_point(Some("claude-turn-1")),
        Err(HistoryError::InvalidRequest(_))
    ));
    assert_eq!(
        projection.fork_point(None).unwrap().length,
        record_bytes(&records)
    );
}

#[tokio::test]
async fn a_whole_fork_ends_at_the_last_finished_turn_before_a_running_turn_writes() {
    let home = TempDir::new().unwrap();
    let mut records = three_turns();
    records.push(json!({"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-16T13:36:00.000Z","content":"fourth"}));
    index_drafts(
        home.path(),
        "running",
        &records,
        &["turn-1", "turn-2", "turn-3"],
    )
    .await;
    let path =
        crate::providers::claude::timeline::resolve_session_path("running", home.path()).unwrap();
    let (projection, _) = project(home.path(), "claude_running", &path, Some("turn-live"));

    let point = projection.fork_point(None).unwrap();

    assert_eq!(point.length, record_bytes(&records[..12]));
    assert_eq!(point.turns, turn_set(&["turn-1", "turn-2", "turn-3"]));
}

#[tokio::test]
async fn a_fork_never_reaches_past_a_running_turn_that_a_reasoning_only_turn_follows() {
    let home = TempDir::new().unwrap();
    let records = three_turns();
    let store = index_drafts(home.path(), "wake", &records, &["turn-1", "turn-2"]).await;
    index_turn(
        &store,
        "claude_wake",
        "turn-wake",
        vec![json!({"type":"reasoning","id":"rs-wake","summary":["Thinking"],"content":[]})],
    )
    .await;
    let path =
        crate::providers::claude::timeline::resolve_session_path("wake", home.path()).unwrap();
    let (projection, _) = project(home.path(), "claude_wake", &path, Some("turn-live"));

    let point = projection.fork_point(None).unwrap();

    assert_eq!(point.length, record_bytes(&records[..6]));
    assert_eq!(point.turns, turn_set(&["turn-1", "turn-2"]));
    assert!(matches!(
        projection.fork_point(Some("turn-wake")),
        Err(HistoryError::InvalidRequest(_))
    ));
}

#[tokio::test]
async fn a_turn_interrupted_during_reasoning_keeps_its_place_before_later_turns() {
    let home = TempDir::new().unwrap();
    let records = three_turns();
    let thread = "claude_cut";
    let entries = all_entries(home.path(), "cut", &records, None);
    let store = Store::new(home.path().to_path_buf());
    let replies = |draft: &str| {
        entries
            .iter()
            .filter(|entry| entry["turnId"] == draft)
            .map(|entry| json!({"type":"agentMessage","id":entry["item"]["id"]}))
            .collect::<Vec<_>>()
    };
    index_turn(&store, thread, "turn-1", replies("claude-turn-1")).await;
    index_turn(
        &store,
        thread,
        "turn-cut",
        vec![json!({"type":"reasoning","id":"rs-cut","summary":[],"content":[]})],
    )
    .await;
    index_turn(&store, thread, "turn-2", replies("claude-turn-2")).await;
    index_turn(&store, thread, "turn-3", replies("claude-turn-3")).await;

    let newest_first = all_turns(home.path(), "cut", Some("turn-3"))
        .iter()
        .map(|turn| turn["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();

    assert_eq!(newest_first, ["turn-3", "turn-2", "turn-cut", "turn-1"]);
}

#[test]
fn image_attachments_survive_live_and_history_user_items() {
    for caption in [None, Some("Inspect this")] {
        let home = TempDir::new().unwrap();
        let mut content = Vec::new();
        if let Some(text) = caption {
            content.push(json!({"type":"text","text":text}));
        }
        content.push(json!({"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}));
        let record = json!({"type":"user","uuid":"image-user","cwd":CWD,"timestamp":"2026-08-16T13:35:01.000Z","message":{"role":"user","content":content}});
        let entries = all_entries(home.path(), "images", std::slice::from_ref(&record), None);
        let mut translator = TurnTranslator::new(
            "claude_images".into(),
            "turn".into(),
            CWD.into(),
            None,
            1_700_000_000_000,
            std::sync::Arc::default(),
        );
        let live = translator.handle(&record);
        let item = &live.notifications[0]["params"]["item"];
        assert_eq!(&entries[0]["item"], item);
        let inputs = item["content"].as_array().unwrap();
        assert_eq!(
            inputs.last().unwrap(),
            &json!({"type":"image","url":"data:image/png;base64,QUJD"})
        );
        assert_eq!(inputs.len(), if caption.is_some() { 2 } else { 1 });
        if let Some(text) = caption {
            assert_eq!(inputs[0]["text"], text);
        }
    }
}
