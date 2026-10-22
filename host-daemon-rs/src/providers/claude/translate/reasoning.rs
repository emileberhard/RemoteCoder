use super::{BlockKind, Translated, TurnTranslator};
use serde_json::{Value, json};

const REASONING_SUMMARY_LIMIT: usize = 4_000;

impl TurnTranslator {
    pub(super) fn open_reasoning_row(&mut self, item_id: String, out: &mut Translated) -> String {
        out.notifications
            .push(self.item_started(reasoning_item(&item_id, &[])));
        self.reasoning_item_id = Some(item_id.clone());
        item_id
    }

    fn complete_reasoning_row(
        &mut self,
        item_id: &str,
        summary: Option<String>,
        out: &mut Translated,
    ) {
        out.notifications
            .push(self.item_completed(reasoning_item(item_id, summary.as_slice())));
        if self.reasoning_item_id.as_deref() == Some(item_id) {
            self.reasoning_item_id = None;
        }
        self.thinking_tokens = 0;
    }

    pub(super) fn synthesized_reasoning_item_id(&self) -> String {
        match self.current_message_id.as_deref() {
            Some(message_id) => format!("{message_id}#thinking"),
            None => format!("{}#thinking", self.turn_id),
        }
    }

    pub(super) fn complete_thinking(&mut self, index: u64, block: &Value, out: &mut Translated) {
        let Some(BlockKind::Thinking {
            reasoning_item_id, ..
        }) = self.blocks.remove(&index)
        else {
            return;
        };
        let text = block
            .get("thinking")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let summary = if text.is_empty() {
            (self.thinking_tokens > 0)
                .then(|| format!("Thought for ~{} tokens", self.thinking_tokens))
        } else {
            Some(clamped_summary(text))
        };
        self.complete_reasoning_row(&reasoning_item_id, summary, out);
    }

    pub(super) fn complete_narration(
        &mut self,
        message_id: &str,
        index: u64,
        text: &str,
        out: &mut Translated,
    ) {
        if let Some(BlockKind::Thinking {
            reasoning_item_id, ..
        }) = self.blocks.remove(&index)
        {
            self.complete_reasoning_row(&reasoning_item_id, None, out);
        }
        self.emit_agent_message(&format!("{message_id}#{index}"), text, out);
    }
}

pub(super) fn reasoning_item(item_id: &str, summary: &[String]) -> Value {
    json!({
        "type": "reasoning",
        "id": item_id,
        "summary": summary,
        "content": [],
    })
}

fn clamped_summary(text: &str) -> String {
    match text.char_indices().nth(REASONING_SUMMARY_LIMIT) {
        Some((end, _)) => format!("{}…", text[..end].trim_end()),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::translator;
    use super::*;

    #[test]
    fn thinking_deltas_wait_for_the_signed_record() {
        let mut t = translator();
        t.handle(
            &json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"msg"}}}),
        );
        t.handle(&json!({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}));

        for thinking in ["", "Checking the logs."] {
            let out = t.handle(&json!({
                "type":"stream_event",
                "event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":thinking}}
            }));
            assert!(out.notifications.is_empty());
        }
    }

    const NARRATION: &str = "/usr/bin contains 932 entries total, reflecting the read-only sealed system volume on macOS. Now I'll count how many of these are symbolic links versus separate files.";

    fn fixture(source: &str) -> Vec<Value> {
        source
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str(line).expect("fixture line is JSON"))
            .collect()
    }

    fn narration_fixture() -> Vec<Value> {
        fixture(include_str!(
            "../../../../tests/fixtures/claude-stream-narration.jsonl"
        ))
    }

    fn replay(lines: &[Value]) -> Vec<Value> {
        let mut t = translator();
        lines
            .iter()
            .flat_map(|line| t.handle(line).notifications)
            .collect()
    }

    fn completed_items<'a>(emitted: &'a [Value], kind: &str) -> Vec<&'a Value> {
        emitted
            .iter()
            .filter(|value| {
                value["method"] == "item/completed" && value["params"]["item"]["type"] == kind
            })
            .map(|value| &value["params"]["item"])
            .collect()
    }

    #[test]
    fn narration_between_tool_calls_becomes_an_agent_message_with_its_history_id() {
        let emitted = replay(&narration_fixture());

        let messages: Vec<_> = completed_items(&emitted, "agentMessage")
            .into_iter()
            .map(|item| (item["id"].clone(), item["text"].clone()))
            .collect();
        assert_eq!(
            messages,
            vec![
                (json!("msg_011CfLQhAj8nGscUV3gSRQfR#1"), json!(NARRATION)),
                (
                    json!("msg_011CfLQhdVxHgWbos9PKRToC#0"),
                    json!("42 of the 932 entries in `/usr/bin` are symbolic links.")
                ),
            ]
        );
        let reasoning: Vec<_> = completed_items(&emitted, "reasoning")
            .into_iter()
            .map(|item| (item["id"].clone(), item["summary"].clone()))
            .collect();
        assert_eq!(
            reasoning,
            vec![
                (
                    json!("msg_011CfLQhAj8nGscUV3gSRQfR#0#thinking"),
                    json!([
                        "The user wants three or four sentences after the count, then another Bash command, followed by a one-line answer."
                    ])
                ),
                (json!("msg_011CfLQhAj8nGscUV3gSRQfR#1#thinking"), json!([])),
            ]
        );
        assert!(!streams_reasoning_deltas(&emitted));
    }

    const SENT_MESSAGE: &str = "```sh\nprintf 'a\\nb\\n' | sort -r | tee /tmp/sorted.txt\n```\n\nIt prints the lines `a` and `b`, then sorts them in reverse order, so `b` comes before `a`. `tee` shows the result in the terminal and also writes it to `/tmp/sorted.txt`, replacing whatever that file contained.";

    #[test]
    fn a_sent_message_between_tool_calls_is_shown_verbatim_instead_of_as_a_tool() {
        let emitted = replay(&fixture(include_str!(
            "../../../../tests/fixtures/claude-stream-sent-message.jsonl"
        )));

        let messages: Vec<_> = completed_items(&emitted, "agentMessage")
            .into_iter()
            .map(|item| (item["id"].clone(), item["text"].clone()))
            .collect();
        assert_eq!(
            messages,
            vec![
                (json!("toolu_01BKxDdLBGhFW5cHjXVxHrkK"), json!(SENT_MESSAGE)),
                (
                    json!("msg_011Cfq1bhoBQGQxtTQvRqjoV#0"),
                    json!(
                        "I ran `echo one`, gave you the command, then ran `echo two`, and both printed as expected."
                    )
                ),
            ]
        );
        let commands: Vec<_> = completed_items(&emitted, "commandExecution")
            .into_iter()
            .map(|item| item["id"].clone())
            .collect();
        assert_eq!(
            commands,
            vec![
                json!("toolu_01Gn35gDNcCJXgMsk38WoEnJ"),
                json!("toolu_017D41bMqwZ4r1t1SWJy9sRC")
            ]
        );
        assert_eq!(
            emitted
                .iter()
                .filter(|value| value["params"]["item"]["id"] == "toolu_01BKxDdLBGhFW5cHjXVxHrkK")
                .count(),
            2
        );
    }

    #[test]
    fn narration_recorded_after_its_block_stop_still_replaces_the_thinking_row() {
        let mut lines = narration_fixture();
        let record = lines
            .iter()
            .position(|line| line.get("narration_block_indexes").is_some())
            .expect("fixture has a narration record");
        assert_eq!(lines[record + 1]["event"]["type"], "content_block_stop");
        lines.swap(record, record + 1);

        let emitted = replay(&lines);

        let row: Vec<_> = completed_items(&emitted, "reasoning")
            .into_iter()
            .filter(|item| item["id"] == "msg_011CfLQhAj8nGscUV3gSRQfR#1#thinking")
            .map(|item| item["summary"].clone())
            .collect();
        assert_eq!(row, vec![json!([])]);
        assert!(
            completed_items(&emitted, "agentMessage")
                .iter()
                .any(|item| item["id"] == "msg_011CfLQhAj8nGscUV3gSRQfR#1"
                    && item["text"] == NARRATION)
        );
    }

    const THINKING_ROW: &str = "msg_011CfQr9ATAjojJ8siRRWkKa#0#thinking";
    const THINKING_SUMMARY: &str = "I'm checking each number for primality, finding 223, 227, 229, 233, and 251 are prime while 221, 231, and 247 factor into smaller primes.";

    fn message_start() -> Value {
        json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"msg"}}})
    }

    fn thinking_block(index: u64, estimated_tokens: Option<i64>, text: &str) -> Vec<Value> {
        let mut lines = vec![json!({
            "type":"stream_event",
            "event":{"type":"content_block_start","index":index,"content_block":{"type":"thinking"}}
        })];
        lines.extend(estimated_tokens.map(
            |tokens| json!({"type":"system","subtype":"thinking_tokens","estimated_tokens":tokens}),
        ));
        lines.push(json!({"type":"assistant","message":{"id":"msg","content":[{"type":"thinking","thinking":text}]}}));
        lines.push(
            json!({"type":"stream_event","event":{"type":"content_block_stop","index":index}}),
        );
        lines
    }

    fn streams_reasoning_deltas(emitted: &[Value]) -> bool {
        emitted.iter().any(|value| {
            value["method"]
                .as_str()
                .unwrap_or_default()
                .starts_with("item/reasoning/")
        })
    }

    fn reasoning_frames(emitted: &[Value]) -> Vec<(Value, Value, Value)> {
        emitted
            .iter()
            .filter(|value| value["params"]["item"]["type"] == "reasoning")
            .map(|value| {
                let item = &value["params"]["item"];
                (
                    value["method"].clone(),
                    item["id"].clone(),
                    item["summary"].clone(),
                )
            })
            .collect()
    }

    fn reasoning_summaries(emitted: &[Value]) -> Vec<Value> {
        completed_items(emitted, "reasoning")
            .into_iter()
            .map(|item| item["summary"].clone())
            .collect()
    }

    #[test]
    fn a_thinking_summary_lands_on_its_reasoning_row() {
        let emitted = replay(&fixture(include_str!(
            "../../../../tests/fixtures/claude-stream-thinking.jsonl"
        )));

        assert_eq!(
            reasoning_frames(&emitted),
            vec![
                (json!("item/started"), json!(THINKING_ROW), json!([])),
                (
                    json!("item/completed"),
                    json!(THINKING_ROW),
                    json!([THINKING_SUMMARY])
                ),
            ]
        );
        assert!(!streams_reasoning_deltas(&emitted));
    }

    #[test]
    fn a_thinking_record_after_its_block_stop_still_completes_the_row() {
        let mut lines = fixture(include_str!(
            "../../../../tests/fixtures/claude-stream-thinking.jsonl"
        ));
        let record = lines
            .iter()
            .position(|line| line["type"] == "assistant")
            .expect("fixture has a thinking record");
        assert_eq!(lines[record + 1]["event"]["type"], "content_block_stop");
        lines.swap(record, record + 1);

        let emitted = replay(&lines);

        assert_eq!(
            reasoning_frames(&emitted),
            vec![
                (json!("item/started"), json!(THINKING_ROW), json!([])),
                (
                    json!("item/completed"),
                    json!(THINKING_ROW),
                    json!([THINKING_SUMMARY])
                ),
            ]
        );
    }

    #[test]
    fn an_empty_thinking_summary_falls_back_to_its_own_token_estimate() {
        let lines = [
            vec![message_start()],
            thinking_block(0, Some(42), "Weighing it."),
            thinking_block(1, None, " \n"),
            thinking_block(2, Some(7), ""),
        ]
        .concat();

        assert_eq!(
            reasoning_summaries(&replay(&lines)),
            vec![
                json!(["Weighing it."]),
                json!([]),
                json!(["Thought for ~7 tokens"])
            ]
        );
    }

    #[test]
    fn a_long_thinking_summary_is_clamped_on_a_character_boundary() {
        let exact = "é".repeat(REASONING_SUMMARY_LIMIT);
        let long = format!("{} tail", "é".repeat(REASONING_SUMMARY_LIMIT - 1));
        let lines = [
            vec![message_start()],
            thinking_block(0, None, &exact),
            thinking_block(1, None, &long),
        ]
        .concat();

        assert_eq!(
            reasoning_summaries(&replay(&lines)),
            vec![
                json!([exact]),
                json!([format!("{}…", "é".repeat(REASONING_SUMMARY_LIMIT - 1))])
            ]
        );
    }

    #[test]
    fn a_thought_cut_off_before_its_record_never_shows_text() {
        let lines = [
            vec![
                json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_cut"}}}),
                json!({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}),
                json!({"type":"system","subtype":"thinking_tokens","estimated_tokens":30}),
                json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Half a thought"}}}),
                message_start(),
            ],
            thinking_block(0, Some(5), "Next thought."),
            vec![json!({
                "type":"result","subtype":"error_during_execution","is_error":true,
                "terminal_reason":"aborted_streaming"
            })],
        ]
        .concat();

        assert_eq!(
            reasoning_frames(&replay(&lines)),
            vec![
                (
                    json!("item/started"),
                    json!("msg_cut#0#thinking"),
                    json!([])
                ),
                (json!("item/started"), json!("msg#0#thinking"), json!([])),
                (
                    json!("item/completed"),
                    json!("msg#0#thinking"),
                    json!(["Next thought."])
                ),
            ]
        );
    }
}
