use super::{BlockKind, TurnTranslator, agent_message_item};
use crate::providers::claude::capacity::CapacityExceeded;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

pub(crate) const MAX_LIVE_BLOCK_BYTES: usize = 1 << 20;
const MAX_GATEWAY_LIVE_BYTES: usize = 16 << 20;

#[derive(Debug, Default)]
pub(crate) struct LivePrefixBudget {
    bytes: AtomicUsize,
}

impl LivePrefixBudget {
    fn reserve(&self, bytes: usize) -> Result<(), CapacityExceeded> {
        self.bytes
            .try_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                current
                    .checked_add(bytes)
                    .filter(|next| *next <= MAX_GATEWAY_LIVE_BYTES)
            })
            .map(|_| ())
            .map_err(|_| CapacityExceeded {
                resource: "gateway live prefix bytes",
                limit: MAX_GATEWAY_LIVE_BYTES,
            })
    }
}

#[derive(Debug)]
struct PrefixAllocation {
    budget: Arc<LivePrefixBudget>,
    bytes: usize,
}

impl PrefixAllocation {
    fn resize(&mut self, bytes: usize) -> Result<(), CapacityExceeded> {
        if bytes > self.bytes {
            self.budget.reserve(bytes - self.bytes)?;
        } else {
            self.budget
                .bytes
                .fetch_sub(self.bytes - bytes, Ordering::AcqRel);
        }
        self.bytes = bytes;
        Ok(())
    }
}

impl Drop for PrefixAllocation {
    fn drop(&mut self) {
        self.budget.bytes.fetch_sub(self.bytes, Ordering::AcqRel);
    }
}

#[derive(Debug)]
enum PrefixState {
    Known {
        text: String,
        allocation: PrefixAllocation,
    },
    Unknown(CapacityExceeded),
}

#[derive(Debug)]
pub(super) struct LivePrefix {
    state: PrefixState,
}

impl LivePrefix {
    pub(super) fn new(budget: Arc<LivePrefixBudget>) -> Self {
        Self {
            state: PrefixState::Known {
                text: String::new(),
                allocation: PrefixAllocation { budget, bytes: 0 },
            },
        }
    }

    fn contents(&self) -> Result<&str, CapacityExceeded> {
        match &self.state {
            PrefixState::Known { text, .. } => Ok(text),
            PrefixState::Unknown(failure) => Err(*failure),
        }
    }

    pub(super) fn append(&mut self, delta: &str) -> Option<CapacityExceeded> {
        let failure = match &mut self.state {
            PrefixState::Unknown(_) => return None,
            PrefixState::Known { text, allocation } => {
                let block_capacity = CapacityExceeded {
                    resource: "live block prefix bytes",
                    limit: MAX_LIVE_BLOCK_BYTES,
                };
                let required = text.len().checked_add(delta.len());
                match required.filter(|bytes| *bytes <= MAX_LIVE_BLOCK_BYTES) {
                    None => Some(block_capacity),
                    Some(required) => {
                        let reserved = if required > text.capacity() {
                            let capacity = required
                                .next_power_of_two()
                                .clamp(256, MAX_LIVE_BLOCK_BYTES);
                            allocation.resize(capacity).and_then(|_| {
                                text.try_reserve_exact(capacity - text.len())
                                    .map_err(|_| block_capacity)?;
                                if text.capacity() > MAX_LIVE_BLOCK_BYTES {
                                    return Err(block_capacity);
                                }
                                allocation.resize(text.capacity())
                            })
                        } else {
                            Ok(())
                        };
                        match reserved {
                            Ok(()) => {
                                text.push_str(delta);
                                None
                            }
                            Err(failure) => Some(failure),
                        }
                    }
                }
            }
        };
        if let Some(failure) = failure {
            self.state = PrefixState::Unknown(failure);
        }
        failure
    }
}

impl TurnTranslator {
    pub(crate) fn live_checkpoint(&self) -> Option<Value> {
        if self.live_finished {
            return None;
        }
        let mut items = indexmap::IndexMap::new();
        let mut unknown = indexmap::IndexMap::new();
        let mut blocks: Vec<_> = self.blocks.iter().collect();
        blocks.sort_by_key(|(index, _)| *index);
        for (_, block) in blocks {
            let (item_id, prefix) = match block {
                BlockKind::Text { item_id, prefix } => (item_id, prefix),
                BlockKind::Thinking {
                    reasoning_item_id,
                    prefix,
                } => (reasoning_item_id, prefix),
                BlockKind::ToolUse => continue,
            };
            match prefix.contents() {
                Ok(text) => {
                    let item = match block {
                        BlockKind::Text { .. } => agent_message_item(item_id, text),
                        BlockKind::Thinking { .. } => {
                            super::reasoning::reasoning_item(item_id, &[])
                        }
                        BlockKind::ToolUse => continue,
                    };
                    items.insert(item_id.clone(), item);
                }
                Err(failure) => {
                    unknown.insert(
                        item_id.clone(),
                        json!({"itemId":item_id, "reason":failure.to_value()}),
                    );
                }
            }
        }
        if let Some(id) = &self.reasoning_item_id {
            items
                .entry(id.clone())
                .or_insert_with(|| super::reasoning::reasoning_item(id, &[]));
        }
        for (id, pending) in &self.pending_tools {
            items.insert(
                id.clone(),
                super::tools::tool_item(
                    id,
                    &pending.tool_name,
                    &pending.input,
                    &self.cwd,
                    super::tools::ToolOutcome::InProgress,
                ),
            );
        }
        if let Some(id) = self
            .compaction_item
            .as_ref()
            .filter(|_| !self.compaction_completed)
        {
            items.insert(id.clone(), json!({"type":"contextCompaction", "id":id}));
        }
        for id in unknown.keys() {
            items.shift_remove(id);
        }
        let live_items: Vec<_> = items
            .into_values()
            .map(|item| json!({"turnId":self.turn_id, "item":item, "isComplete":false}))
            .collect();
        let mut active_turn = self.turn_started()["params"]["turn"].clone();
        active_turn["itemsView"] = json!("notLoaded");
        Some(
            json!({"status":"observed", "threadId":self.thread_id, "turnId":self.turn_id,
            "epoch":self.live_epoch, "throughSequence":self.live_sequence,
            "activeTurn":active_turn,
            "liveItems":live_items, "unknownItems":unknown.into_values().collect::<Vec<_>>() }),
        )
    }

    pub(crate) fn end_live_state(&mut self) {
        self.live_finished = true;
        self.blocks.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn translator(budget: Arc<LivePrefixBudget>) -> TurnTranslator {
        TurnTranslator::new(
            "claude_a".into(),
            "turn-a".into(),
            "/tmp".into(),
            None,
            0,
            budget,
        )
    }

    fn open(t: &mut TurnTranslator, kind: &str, initial: &str) -> super::super::Translated {
        t.handle(&json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"message-a"}}}));
        let field = if kind == "thinking" {
            "thinking"
        } else {
            "text"
        };
        t.handle(
            &json!({"type":"stream_event","event":{"type":"content_block_start","index":0,
            "content_block":{"type":kind,field:initial}}}),
        )
    }

    fn append(t: &mut TurnTranslator, kind: &str, text: &str) -> super::super::Translated {
        let field = if kind == "thinking" {
            "thinking"
        } else {
            "text"
        };
        t.handle(
            &json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,
            "delta":{"type":format!("{field}_delta"),field:text}}}),
        )
    }

    #[test]
    fn live_checkpoint_block_capacity_is_unknown_once_and_unsigned_thinking_stays_hidden() {
        for kind in ["text", "thinking"] {
            let budget = Arc::new(LivePrefixBudget::default());
            let mut t = translator(Arc::clone(&budget));
            let initial = open(&mut t, kind, "A");
            if kind == "text" {
                assert_eq!(initial.notifications[0]["params"]["item"]["text"], "A");
            }
            append(&mut t, kind, &"b".repeat(MAX_LIVE_BLOCK_BYTES - 1));
            let known = t.live_checkpoint().unwrap();
            assert_eq!(known["unknownItems"], json!([]));
            if kind == "text" {
                assert_eq!(
                    known["liveItems"][0]["item"]["text"]
                        .as_str()
                        .unwrap()
                        .len(),
                    MAX_LIVE_BLOCK_BYTES
                );
            } else {
                assert_eq!(known["liveItems"][0]["item"]["summary"], json!([]));
                assert_eq!(known["liveItems"][0]["item"]["content"], json!([]));
            }
            let overflow = append(&mut t, kind, "c");
            assert!(overflow.capacity_error.is_none());
            assert_eq!(overflow.live_prefix_failures.len(), 1);
            assert_eq!(
                overflow.live_prefix_failures[0].1.limit,
                MAX_LIVE_BLOCK_BYTES
            );
            assert_eq!(budget.bytes.load(Ordering::Acquire), 0);
            if kind == "thinking" {
                assert!(overflow.notifications.is_empty());
            }
            assert!(append(&mut t, kind, "d").live_prefix_failures.is_empty());
            let unknown = t.live_checkpoint().unwrap();
            assert_eq!(unknown["liveItems"], json!([]));
            assert_eq!(unknown["unknownItems"][0]["reason"]["kind"], "capacity");
            assert_eq!(
                unknown["unknownItems"][0]["reason"]["resource"],
                "live block prefix bytes"
            );
            let block = if kind == "text" {
                json!({"type":"text","text":"Canonical answer"})
            } else {
                json!({"type":"thinking","thinking":"Signed thought","signature":"signed"})
            };
            let completed = t.handle(
                &json!({"type":"assistant","message":{"id":"message-a","content":[block]}}),
            );
            assert_eq!(completed.notifications[0]["method"], "item/completed");
            assert_eq!(t.live_checkpoint().unwrap()["unknownItems"], json!([]));
            assert_eq!(budget.bytes.load(Ordering::Acquire), 0);
        }
    }

    #[test]
    fn live_checkpoint_gateway_capacity_is_shared_and_released_at_every_owner_boundary() {
        let budget = Arc::new(LivePrefixBudget::default());
        let text = "x".repeat(MAX_LIVE_BLOCK_BYTES);
        let mut owners = (0..16)
            .map(|_| {
                let mut t = translator(Arc::clone(&budget));
                open(&mut t, "text", "");
                append(&mut t, "text", &text);
                t
            })
            .collect::<Vec<_>>();
        assert_eq!(budget.bytes.load(Ordering::Acquire), MAX_GATEWAY_LIVE_BYTES);
        let mut refused = translator(Arc::clone(&budget));
        open(&mut refused, "text", "");
        let failure = append(&mut refused, "text", "suffix");
        assert!(failure.capacity_error.is_none());
        assert_eq!(failure.notifications[0]["params"]["delta"], "suffix");
        assert_eq!(
            failure.live_prefix_failures[0].1.resource,
            "gateway live prefix bytes"
        );
        assert_eq!(refused.live_checkpoint().unwrap()["liveItems"], json!([]));
        owners[0].handle(&json!({"type":"assistant","message":{"id":"message-a","content":[{"type":"text","text":"Complete"}]}}));
        assert_eq!(
            budget.bytes.load(Ordering::Acquire),
            MAX_GATEWAY_LIVE_BYTES - MAX_LIVE_BLOCK_BYTES
        );
        let mut admitted = translator(Arc::clone(&budget));
        assert!(
            open(&mut admitted, "text", &text)
                .live_prefix_failures
                .is_empty()
        );
        owners[1].handle(&json!({"type":"result","subtype":"success","result":"Complete"}));
        assert!(owners[1].live_checkpoint().is_none());
        assert_eq!(
            budget.bytes.load(Ordering::Acquire),
            MAX_GATEWAY_LIVE_BYTES - MAX_LIVE_BLOCK_BYTES
        );
        let epoch = owners[2].live_checkpoint().unwrap()["epoch"].clone();
        drop(owners.remove(2));
        let mut replacement = translator(Arc::clone(&budget));
        assert!(
            open(&mut replacement, "text", &text)
                .live_prefix_failures
                .is_empty()
        );
        assert_ne!(replacement.live_checkpoint().unwrap()["epoch"], epoch);
        drop((owners, admitted, refused, replacement));
        assert_eq!(budget.bytes.load(Ordering::Acquire), 0);
    }
}
