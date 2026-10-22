use std::collections::{HashMap, HashSet};
use std::fmt;

use serde::{Deserialize, Serialize};

const SENT_TURN_KEY_TTL_SECONDS: f64 = 24.0 * 60.0 * 60.0;
const MAX_SENT_TURN_KEYS: usize = 5000;
pub(crate) const MAX_UNTRACKED_TURN_CONTEXTS: usize = 64;
pub(crate) const MAX_QUEUED_SUBMISSIONS_PER_THREAD: usize = 100;
pub(crate) const MAX_QUEUED_THREADS: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct TurnKey {
    thread_id: String,
    turn_id: String,
}

impl TurnKey {
    pub(crate) fn new(thread_id: impl Into<String>, turn_id: impl Into<String>) -> Self {
        Self {
            thread_id: thread_id.into(),
            turn_id: turn_id.into(),
        }
    }

    pub(crate) fn thread_id(&self) -> &str {
        &self.thread_id
    }

    pub(crate) fn turn_id(&self) -> &str {
        &self.turn_id
    }

    fn parse_stored(stored: &str) -> Option<Self> {
        let (thread_id, turn_id) = stored.split_once('|')?;
        Some(Self::new(thread_id, turn_id))
    }
}

impl fmt::Display for TurnKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}|{}", self.thread_id, self.turn_id)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PromptContext {
    #[serde(default)]
    pub(crate) compaction: bool,
    pub(crate) preview: String,
    pub(crate) cwd: Option<String>,
    pub(crate) owner_client_id: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TurnContext {
    #[serde(default)]
    pub(crate) compaction: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) awaiting_attribution: bool,
    pub(crate) prompt_preview: String,
    pub(crate) cwd: Option<String>,
    pub(crate) last_message_preview: Option<String>,
    pub(crate) created_at_unix_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ActiveTurn {
    pub(crate) thread_id: String,
    pub(crate) turn_id: String,
    pub(crate) owner_client_id: u64,
    pub(crate) started_at_unix_seconds: f64,
    pub(crate) last_seen_at_unix_seconds: f64,
}

impl ActiveTurn {
    pub(crate) fn key(&self) -> TurnKey {
        TurnKey::new(&self.thread_id, &self.turn_id)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PendingTurnStart {
    pub(crate) thread_id: String,
    pub(crate) context: PromptContext,
    pub(crate) previous_turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) client_user_message_id: Option<String>,
    pub(crate) created_at_unix_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct QueuedSubmission {
    pub(crate) client_user_message_id: String,
    pub(crate) queued_submission_id: Option<String>,
    pub(crate) context: PromptContext,
    pub(crate) created_at_unix_seconds: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ThreadQueue {
    pub(crate) held: bool,
    pub(crate) submissions: Vec<QueuedSubmission>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum QueueRefusal {
    ThreadFull,
    TooManyThreads,
}

impl fmt::Display for QueueRefusal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::ThreadFull => {
                "This conversation already has the most queued messages the gateway tracks"
            }
            Self::TooManyThreads => {
                "Too many conversations have queued messages; send or remove some first"
            }
        })
    }
}

/// The persisted shape: turn keys are stored as `"<thread>|<turn>"` strings.
#[derive(Debug, Default)]
pub(crate) struct DurableTurns {
    pub(crate) pending_turn_starts: HashMap<String, PendingTurnStart>,
    pub(crate) active_turns_by_key: HashMap<String, ActiveTurn>,
    pub(crate) turn_ctx_by_key: HashMap<String, TurnContext>,
    pub(crate) queued_submissions: HashMap<String, ThreadQueue>,
}

#[derive(Debug)]
pub(crate) enum Completion {
    AlreadyRecorded,
    Recorded(TurnContext),
}

#[derive(Debug, Default)]
pub(crate) struct TurnLedger {
    pending: HashMap<String, PendingTurnStart>,
    active: HashMap<TurnKey, ActiveTurn>,
    active_by_thread: HashMap<String, TurnKey>,
    contexts: HashMap<TurnKey, TurnContext>,
    completed: HashMap<TurnKey, f64>,
    queues: HashMap<String, ThreadQueue>,
    in_flight_queue_adds: HashMap<String, usize>,
}

pub(crate) fn is_durable_codex_thread(thread_id: &str) -> bool {
    !crate::providers::claude::is_claude_thread_id(thread_id)
}

/// Human-facing provider name for push copy, derived from the thread id.
pub(crate) fn agent_label(thread_id: &str) -> &'static str {
    if crate::providers::claude::is_claude_thread_id(thread_id) {
        "Claude"
    } else {
        "Codex"
    }
}

fn default_prompt_preview(thread_id: &str) -> String {
    format!("{} task", agent_label(thread_id))
}

impl TurnLedger {
    pub(crate) fn restore(durable: DurableTurns) -> Self {
        let pending = durable
            .pending_turn_starts
            .into_iter()
            .filter(|(_, pending)| is_durable_codex_thread(&pending.thread_id))
            .collect();
        let active: HashMap<TurnKey, ActiveTurn> = durable
            .active_turns_by_key
            .into_values()
            .filter(|turn| is_durable_codex_thread(&turn.thread_id))
            .map(|turn| (turn.key(), turn))
            .collect();
        let active_by_thread = active
            .keys()
            .map(|key| (key.thread_id().to_owned(), key.clone()))
            .collect();
        let contexts = durable
            .turn_ctx_by_key
            .into_iter()
            .filter_map(|(stored, context)| {
                let key = TurnKey::parse_stored(&stored)?;
                is_durable_codex_thread(key.thread_id()).then_some((key, context))
            })
            .collect();
        let queues = durable
            .queued_submissions
            .into_iter()
            .filter(|(thread, queue)| {
                is_durable_codex_thread(thread) && !queue.submissions.is_empty()
            })
            .collect();
        let mut ledger = Self {
            pending,
            active,
            active_by_thread,
            contexts,
            completed: HashMap::new(),
            queues,
            in_flight_queue_adds: HashMap::new(),
        };
        ledger.bound_untracked_contexts();
        ledger
    }

    pub(crate) fn durable(&self) -> DurableTurns {
        DurableTurns {
            pending_turn_starts: self
                .pending
                .iter()
                .filter(|(_, pending)| is_durable_codex_thread(&pending.thread_id))
                .map(|(key, pending)| (key.clone(), pending.clone()))
                .collect(),
            active_turns_by_key: self
                .active
                .iter()
                .filter(|(key, _)| is_durable_codex_thread(key.thread_id()))
                .map(|(key, turn)| (key.to_string(), turn.clone()))
                .collect(),
            turn_ctx_by_key: self
                .contexts
                .iter()
                .filter(|(key, _)| is_durable_codex_thread(key.thread_id()))
                .map(|(key, context)| (key.to_string(), context.clone()))
                .collect(),
            queued_submissions: self
                .queues
                .iter()
                .filter(|(thread, _)| is_durable_codex_thread(thread))
                .map(|(thread, queue)| (thread.clone(), queue.clone()))
                .collect(),
        }
    }

    pub(crate) fn queues_are_bounded(queues: &HashMap<String, ThreadQueue>) -> bool {
        queues.len() <= MAX_QUEUED_THREADS
            && queues.iter().all(|(thread, queue)| {
                !thread.is_empty()
                    && queue.submissions.len() <= MAX_QUEUED_SUBMISSIONS_PER_THREAD
                    && queue
                        .submissions
                        .iter()
                        .all(|submission| !submission.client_user_message_id.is_empty())
            })
    }

    pub(crate) fn next_owner_client_id(&self) -> u64 {
        self.pending
            .values()
            .map(|pending| pending.context.owner_client_id)
            .chain(self.active.values().map(|turn| turn.owner_client_id))
            .chain(
                self.queues
                    .values()
                    .flat_map(|queue| &queue.submissions)
                    .map(|submission| submission.context.owner_client_id),
            )
            .max()
            .unwrap_or_default()
            .saturating_add(1)
            .max(1)
    }

    pub(crate) fn insert_pending(&mut self, request_key: String, pending: PendingTurnStart) {
        self.pending.insert(request_key, pending);
    }

    pub(crate) fn pending(&self) -> impl Iterator<Item = (&String, &PendingTurnStart)> {
        self.pending.iter()
    }

    #[cfg(test)]
    pub(crate) fn pending_start(&self, request_key: &str) -> Option<&PendingTurnStart> {
        self.pending.get(request_key)
    }

    pub(crate) fn take_pending(&mut self, request_key: &str) -> Option<PendingTurnStart> {
        self.pending.remove(request_key)
    }

    pub(crate) fn take_pending_matching(
        &mut self,
        request_key: &str,
        expected: &PendingTurnStart,
    ) -> Option<PendingTurnStart> {
        if self.pending.get(request_key) != Some(expected) {
            return None;
        }
        self.pending.remove(request_key)
    }

    pub(crate) fn active(&self) -> impl Iterator<Item = &ActiveTurn> {
        self.active.values()
    }

    pub(crate) fn active_keys(&self) -> impl Iterator<Item = &TurnKey> {
        self.active.keys()
    }

    pub(crate) fn active_count(&self) -> usize {
        self.active.len()
    }

    pub(crate) fn is_active(&self, key: &TurnKey) -> bool {
        self.active.contains_key(key)
    }

    pub(crate) fn active_turn(&self, key: &TurnKey) -> Option<&ActiveTurn> {
        self.active.get(key)
    }

    pub(crate) fn active_on_thread(&self, thread_id: &str) -> Option<&ActiveTurn> {
        self.active_by_thread
            .get(thread_id)
            .and_then(|key| self.active.get(key))
    }

    pub(crate) fn active_with_context(
        &self,
    ) -> impl Iterator<Item = (&ActiveTurn, Option<&TurnContext>)> {
        self.active
            .iter()
            .map(|(key, turn)| (turn, self.contexts.get(key)))
    }

    pub(crate) fn note_compaction(&mut self, key: &TurnKey) {
        if self
            .contexts
            .get(key)
            .is_some_and(|context| context.awaiting_attribution)
            && let Some(pending) = self
                .take_oldest_pending_where(key.thread_id(), |pending| pending.context.compaction)
        {
            self.attribute(key, pending.context);
        }
        if let Some(context) = self.contexts.get_mut(key) {
            context.compaction = true;
        }
    }

    #[cfg(test)]
    pub(crate) fn context(&self, key: &TurnKey) -> Option<&TurnContext> {
        self.contexts.get(key)
    }

    #[cfg(test)]
    pub(crate) fn context_count(&self) -> usize {
        self.contexts.len()
    }

    #[cfg(test)]
    pub(crate) fn completion_recorded(&self, key: &TurnKey) -> bool {
        self.completed.contains_key(key)
    }

    pub(crate) fn mark_active(
        &mut self,
        key: &TurnKey,
        now: f64,
        started_at: Option<f64>,
        owner_client_id: Option<u64>,
    ) {
        if let Some(previous) = self.active_by_thread.get(key.thread_id())
            && previous != key
        {
            self.active.remove(previous);
        }
        self.active_by_thread
            .insert(key.thread_id().to_owned(), key.clone());

        match self.active.get_mut(key) {
            None => {
                self.active.insert(
                    key.clone(),
                    ActiveTurn {
                        thread_id: key.thread_id().to_owned(),
                        turn_id: key.turn_id().to_owned(),
                        owner_client_id: owner_client_id.unwrap_or_default(),
                        started_at_unix_seconds: started_at.unwrap_or(now),
                        last_seen_at_unix_seconds: now,
                    },
                );
            }
            Some(existing) => {
                existing.last_seen_at_unix_seconds = now;
                if let Some(started_at) = started_at {
                    existing.started_at_unix_seconds = started_at;
                }
                if let Some(owner_client_id) = owner_client_id {
                    existing.owner_client_id = owner_client_id;
                }
            }
        }
        self.bound_untracked_contexts();
    }

    pub(crate) fn mark_inactive(&mut self, key: &TurnKey) {
        if self.active_by_thread.get(key.thread_id()) == Some(key) {
            self.active_by_thread.remove(key.thread_id());
        }
        self.active.remove(key);
    }

    pub(crate) fn start_from_pending(
        &mut self,
        pending: PendingTurnStart,
        turn_id: &str,
        now: f64,
        started_at: Option<f64>,
    ) {
        let key = TurnKey::new(&pending.thread_id, turn_id);
        self.mark_active(&key, now, started_at, Some(pending.context.owner_client_id));
        self.contexts.insert(
            key,
            TurnContext {
                compaction: pending.context.compaction,
                awaiting_attribution: false,
                prompt_preview: pending.context.preview,
                cwd: pending.context.cwd,
                last_message_preview: None,
                created_at_unix_seconds: now,
            },
        );
    }

    pub(crate) fn note_started(&mut self, key: &TurnKey, now: f64) -> bool {
        if self.completed.contains_key(key) {
            return false;
        }
        if let Some(queue) = self.queues.get_mut(key.thread_id()) {
            queue.held = false;
        }
        if self.contexts.contains_key(key) {
            self.mark_active(key, now, Some(now), None);
            return true;
        }
        if !self.binds_by_position(key.thread_id()) {
            self.note_unattributed(key, now, 0);
            return true;
        }
        let prompt = self
            .take_oldest_pending_for_thread(key.thread_id())
            .map(|pending| pending.context);
        let compaction = prompt.as_ref().is_some_and(|prompt| prompt.compaction);
        let owner_client_id = prompt
            .as_ref()
            .map(|prompt| prompt.owner_client_id)
            .unwrap_or_default();
        let (prompt_preview, cwd) = match prompt {
            Some(prompt) => (prompt.preview, prompt.cwd),
            None => (default_prompt_preview(key.thread_id()), None),
        };
        self.mark_active(key, now, Some(now), Some(owner_client_id));
        self.contexts.insert(
            key.clone(),
            TurnContext {
                compaction,
                awaiting_attribution: false,
                prompt_preview,
                cwd,
                last_message_preview: None,
                created_at_unix_seconds: now,
            },
        );
        true
    }

    fn binds_by_position(&self, thread_id: &str) -> bool {
        !self.queues.contains_key(thread_id)
            && !self.pending.values().any(|pending| {
                pending.thread_id == thread_id && pending.client_user_message_id.is_some()
            })
    }

    fn note_unattributed(&mut self, key: &TurnKey, now: f64, owner_client_id: u64) {
        self.mark_active(key, now, Some(now), Some(owner_client_id));
        self.contexts.insert(
            key.clone(),
            TurnContext {
                compaction: false,
                awaiting_attribution: true,
                prompt_preview: default_prompt_preview(key.thread_id()),
                cwd: None,
                last_message_preview: None,
                created_at_unix_seconds: now,
            },
        );
    }

    pub(crate) fn note_queue_started(&mut self, key: &TurnKey, owner_client_id: u64, now: f64) {
        if let Some(queue) = self.queues.get_mut(key.thread_id()) {
            queue.held = false;
        }
        if self.completed.contains_key(key) {
            return;
        }
        if !self.contexts.contains_key(key) {
            self.note_unattributed(key, now, owner_client_id);
            return;
        }
        self.mark_active(key, now, None, None);
        if let Some(turn) = self.active.get_mut(key)
            && turn.owner_client_id == 0
        {
            turn.owner_client_id = owner_client_id;
        }
    }

    pub(crate) fn note_user_message(
        &mut self,
        key: &TurnKey,
        client_user_message_id: &str,
    ) -> bool {
        let queued = self.take_queued(key.thread_id(), client_user_message_id);
        let consumed = queued.is_some();
        if !self
            .contexts
            .get(key)
            .is_some_and(|context| context.awaiting_attribution)
        {
            return consumed;
        }
        let prompt = match queued {
            Some(submission) => Some(submission.context),
            None => self
                .take_pending_with_message(key.thread_id(), client_user_message_id)
                .map(|pending| pending.context),
        };
        match prompt {
            Some(prompt) => {
                self.attribute(key, prompt);
                true
            }
            None => consumed,
        }
    }

    fn attribute(&mut self, key: &TurnKey, prompt: PromptContext) {
        if let Some(turn) = self.active.get_mut(key) {
            turn.owner_client_id = prompt.owner_client_id;
        }
        if let Some(context) = self.contexts.get_mut(key) {
            context.awaiting_attribution = false;
            context.compaction = prompt.compaction;
            context.prompt_preview = prompt.preview;
            context.cwd = prompt.cwd;
        }
    }

    fn take_queued(
        &mut self,
        thread_id: &str,
        client_user_message_id: &str,
    ) -> Option<QueuedSubmission> {
        let queue = self.queues.get_mut(thread_id)?;
        let index = queue
            .submissions
            .iter()
            .position(|submission| submission.client_user_message_id == client_user_message_id)?;
        let submission = queue.submissions.remove(index);
        if queue.submissions.is_empty() {
            self.queues.remove(thread_id);
        }
        Some(submission)
    }

    fn take_pending_with_message(
        &mut self,
        thread_id: &str,
        client_user_message_id: &str,
    ) -> Option<PendingTurnStart> {
        let key = self
            .pending
            .iter()
            .find(|(_, pending)| {
                pending.thread_id == thread_id
                    && pending.client_user_message_id.as_deref() == Some(client_user_message_id)
            })
            .map(|(key, _)| key.clone())?;
        self.pending.remove(&key)
    }

    pub(crate) fn thread_cwd(&self, thread_id: &str) -> Option<String> {
        let key = self.active_by_thread.get(thread_id)?;
        self.contexts.get(key)?.cwd.clone()
    }

    pub(crate) fn begin_queue_add(
        &mut self,
        thread_id: &str,
        submission: QueuedSubmission,
    ) -> Result<(), QueueRefusal> {
        self.enqueue(thread_id, submission)?;
        *self
            .in_flight_queue_adds
            .entry(thread_id.to_owned())
            .or_default() += 1;
        Ok(())
    }

    pub(crate) fn finish_queue_add(&mut self, thread_id: &str) {
        let count = self
            .in_flight_queue_adds
            .get_mut(thread_id)
            .expect("queue add has an owner");
        *count -= 1;
        if *count == 0 {
            self.in_flight_queue_adds.remove(thread_id);
        }
    }

    pub(crate) fn enqueue(
        &mut self,
        thread_id: &str,
        submission: QueuedSubmission,
    ) -> Result<(), QueueRefusal> {
        let tracked_threads = self.queues.len();
        match self.queues.get_mut(thread_id) {
            Some(queue) if queue.submissions.len() >= MAX_QUEUED_SUBMISSIONS_PER_THREAD => {
                Err(QueueRefusal::ThreadFull)
            }
            Some(queue) => {
                queue.submissions.push(submission);
                Ok(())
            }
            None if tracked_threads >= MAX_QUEUED_THREADS => Err(QueueRefusal::TooManyThreads),
            None => {
                self.queues.insert(
                    thread_id.to_owned(),
                    ThreadQueue {
                        held: false,
                        submissions: vec![submission],
                    },
                );
                Ok(())
            }
        }
    }

    pub(crate) fn queue_accepted(
        &mut self,
        thread_id: &str,
        client_user_message_id: &str,
        queued_submission_id: &str,
    ) -> bool {
        let Some(submission) = self.queues.get_mut(thread_id).and_then(|queue| {
            queue.submissions.iter_mut().find(|submission| {
                submission.client_user_message_id == client_user_message_id
                    && submission.queued_submission_id.is_none()
            })
        }) else {
            return false;
        };
        submission.queued_submission_id = Some(queued_submission_id.to_owned());
        true
    }

    pub(crate) fn queue_not_added(
        &mut self,
        thread_id: &str,
        client_user_message_id: &str,
    ) -> bool {
        self.remove_queued(thread_id, |submission| {
            submission.client_user_message_id == client_user_message_id
                && submission.queued_submission_id.is_none()
        })
    }

    pub(crate) fn queue_deleted(&mut self, thread_id: &str, queued_submission_id: &str) -> bool {
        self.remove_queued(thread_id, |submission| {
            submission.queued_submission_id.as_deref() == Some(queued_submission_id)
        })
    }

    fn remove_queued(
        &mut self,
        thread_id: &str,
        matches: impl Fn(&QueuedSubmission) -> bool,
    ) -> bool {
        let Some(queue) = self.queues.get_mut(thread_id) else {
            return false;
        };
        let Some(index) = queue.submissions.iter().rposition(matches) else {
            return false;
        };
        queue.submissions.remove(index);
        if queue.submissions.is_empty() {
            self.queues.remove(thread_id);
        }
        true
    }

    pub(crate) fn settle_queue(
        &mut self,
        thread_id: &str,
        listed: &HashSet<String>,
        listed_at: f64,
        hold: bool,
    ) -> bool {
        if self.in_flight_queue_adds.contains_key(thread_id) {
            return false;
        }
        let Some(queue) = self.queues.get_mut(thread_id) else {
            return false;
        };
        let before = (queue.submissions.len(), queue.held);
        queue.submissions.retain(|submission| {
            listed.contains(&submission.client_user_message_id)
                || submission.created_at_unix_seconds >= listed_at
        });
        if queue.submissions.is_empty() {
            self.queues.remove(thread_id);
            return true;
        }
        queue.held |= hold
            && queue
                .submissions
                .iter()
                .any(|submission| listed.contains(&submission.client_user_message_id));
        before != (queue.submissions.len(), queue.held)
    }

    pub(crate) fn hold_queue(&mut self, thread_id: &str) -> bool {
        match self.queues.get_mut(thread_id) {
            Some(queue) if !queue.held => {
                queue.held = true;
                true
            }
            _ => false,
        }
    }

    pub(crate) fn awaits_queued_successor(&self, thread_id: &str) -> bool {
        self.queues.get(thread_id).is_some_and(|queue| !queue.held)
    }

    pub(crate) fn observable_queue_threads(&self, owner_client_id: Option<u64>) -> Vec<String> {
        self.queues
            .iter()
            .filter(|(thread, queue)| {
                !queue.held
                    && is_durable_codex_thread(thread)
                    && owner_client_id.is_none_or(|owner| {
                        queue
                            .submissions
                            .iter()
                            .any(|submission| submission.context.owner_client_id == owner)
                    })
            })
            .map(|(thread, _)| thread.clone())
            .collect()
    }

    pub(crate) fn note_last_message(&mut self, key: TurnKey, preview: String, now: f64) {
        if self.completed.contains_key(&key) {
            return;
        }
        let default_preview = default_prompt_preview(key.thread_id());
        self.contexts
            .entry(key)
            .or_insert_with(|| TurnContext {
                compaction: false,
                awaiting_attribution: false,
                prompt_preview: default_preview,
                cwd: None,
                last_message_preview: None,
                created_at_unix_seconds: now,
            })
            .last_message_preview = Some(preview);
        self.bound_untracked_contexts();
    }

    pub(crate) fn complete(&mut self, key: &TurnKey, now: f64) -> Completion {
        self.mark_inactive(key);
        self.prune_completed(now);
        if self.completed.contains_key(key) {
            return Completion::AlreadyRecorded;
        }
        self.completed.insert(key.clone(), now);

        let context = self.contexts.remove(key).unwrap_or_else(|| {
            let prompt = if self.binds_by_position(key.thread_id()) {
                self.take_oldest_pending_for_thread(key.thread_id())
            } else {
                None
            }
            .map(|pending| pending.context);
            let compaction = prompt.as_ref().is_some_and(|prompt| prompt.compaction);
            let (prompt_preview, cwd) = match prompt {
                Some(prompt) => (prompt.preview, prompt.cwd),
                None => (default_prompt_preview(key.thread_id()), None),
            };
            TurnContext {
                compaction,
                awaiting_attribution: false,
                prompt_preview,
                cwd,
                last_message_preview: None,
                created_at_unix_seconds: now,
            }
        });
        Completion::Recorded(context)
    }

    fn take_oldest_pending_for_thread(&mut self, thread_id: &str) -> Option<PendingTurnStart> {
        self.take_oldest_pending_where(thread_id, |_| true)
    }

    fn take_oldest_pending_where(
        &mut self,
        thread_id: &str,
        eligible: impl Fn(&PendingTurnStart) -> bool,
    ) -> Option<PendingTurnStart> {
        let key = self
            .pending
            .iter()
            .filter(|(_, pending)| pending.thread_id == thread_id && eligible(pending))
            .min_by(|left, right| {
                left.1
                    .created_at_unix_seconds
                    .total_cmp(&right.1.created_at_unix_seconds)
            })
            .map(|(key, _)| key.clone())?;
        self.pending.remove(&key)
    }

    fn bound_untracked_contexts(&mut self) {
        let mut untracked: Vec<(TurnKey, f64)> = self
            .contexts
            .iter()
            .filter(|(key, _)| !self.active.contains_key(*key))
            .map(|(key, context)| (key.clone(), context.created_at_unix_seconds))
            .collect();
        let excess = untracked.len().saturating_sub(MAX_UNTRACKED_TURN_CONTEXTS);
        if excess == 0 {
            return;
        }
        untracked.sort_by(|a, b| a.1.total_cmp(&b.1));
        for (key, _) in untracked.into_iter().take(excess) {
            self.contexts.remove(&key);
        }
    }

    fn prune_completed(&mut self, now: f64) {
        if self.completed.is_empty() {
            return;
        }

        let cutoff = now - SENT_TURN_KEY_TTL_SECONDS;
        self.completed
            .retain(|_, recorded_at| *recorded_at >= cutoff);
        if self.completed.len() <= MAX_SENT_TURN_KEYS {
            return;
        }

        let mut ordered: Vec<(TurnKey, f64)> = self
            .completed
            .iter()
            .map(|(key, recorded_at)| (key.clone(), *recorded_at))
            .collect();
        ordered.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        let excess = ordered.len().saturating_sub(MAX_SENT_TURN_KEYS);
        for (key, _) in ordered.into_iter().take(excess) {
            self.completed.remove(&key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending(thread_id: &str, created_at: f64, owner_client_id: u64) -> PendingTurnStart {
        PendingTurnStart {
            thread_id: thread_id.to_owned(),
            context: PromptContext {
                compaction: false,
                preview: format!("prompt {created_at}"),
                cwd: Some("/work".to_owned()),
                owner_client_id,
            },
            previous_turn_id: None,
            client_user_message_id: None,
            created_at_unix_seconds: created_at,
        }
    }

    #[test]
    fn stored_keys_keep_the_thread_pipe_turn_format() {
        let mut ledger = TurnLedger::default();
        ledger.insert_pending("3:1".to_owned(), pending("thread", 1.0, 3));
        ledger.note_started(&TurnKey::new("thread", "turn"), 5.0);

        let durable = ledger.durable();
        assert_eq!(
            durable.active_turns_by_key.keys().collect::<Vec<_>>(),
            ["thread|turn"]
        );
        assert_eq!(
            durable.turn_ctx_by_key.keys().collect::<Vec<_>>(),
            ["thread|turn"]
        );
        assert_eq!(
            durable.turn_ctx_by_key["thread|turn"].prompt_preview,
            "prompt 1"
        );

        let restored = TurnLedger::restore(durable);
        assert_eq!(
            restored
                .active_on_thread("thread")
                .map(|turn| turn.owner_client_id),
            Some(3)
        );
        assert_eq!(restored.next_owner_client_id(), 4);
    }

    #[test]
    fn restore_drops_claude_threads_and_unparseable_context_keys() {
        let context = |preview: &str| TurnContext {
            compaction: false,
            awaiting_attribution: false,
            prompt_preview: preview.to_owned(),
            cwd: None,
            last_message_preview: None,
            created_at_unix_seconds: 1.0,
        };
        let restored = TurnLedger::restore(DurableTurns {
            pending_turn_starts: HashMap::from([
                ("1:1".to_owned(), pending("claude_a", 1.0, 1)),
                ("1:2".to_owned(), pending("codex-a", 1.0, 1)),
            ]),
            active_turns_by_key: HashMap::new(),
            turn_ctx_by_key: HashMap::from([
                ("codex-a|turn".to_owned(), context("kept")),
                ("claude_a|turn".to_owned(), context("claude")),
                ("no-separator".to_owned(), context("malformed")),
            ]),
            queued_submissions: HashMap::new(),
        });

        assert_eq!(restored.pending().count(), 1);
        assert_eq!(restored.context_count(), 1);
        assert!(restored.context(&TurnKey::new("codex-a", "turn")).is_some());
    }

    #[test]
    fn a_completion_is_recorded_once_and_consumes_its_context() {
        let mut ledger = TurnLedger::default();
        let key = TurnKey::new("thread", "turn");
        ledger.note_started(&key, 1.0);
        ledger.note_last_message(key.clone(), "done".to_owned(), 2.0);

        let Completion::Recorded(context) = ledger.complete(&key, 3.0) else {
            panic!("first completion must be recorded");
        };
        assert_eq!(context.last_message_preview.as_deref(), Some("done"));
        assert!(!ledger.is_active(&key));
        assert!(matches!(
            ledger.complete(&key, 4.0),
            Completion::AlreadyRecorded
        ));
        ledger.note_last_message(key.clone(), "late".to_owned(), 5.0);
        assert!(ledger.context(&key).is_none());
    }

    #[test]
    fn a_new_turn_on_a_thread_replaces_its_active_turn() {
        let mut ledger = TurnLedger::default();
        ledger.mark_active(&TurnKey::new("thread", "a"), 1.0, Some(1.0), Some(1));
        ledger.mark_active(&TurnKey::new("thread", "b"), 2.0, Some(2.0), Some(1));

        assert_eq!(ledger.active_count(), 1);
        assert_eq!(
            ledger
                .active_on_thread("thread")
                .map(|turn| turn.turn_id.as_str()),
            Some("b")
        );
        ledger.mark_inactive(&TurnKey::new("thread", "a"));
        assert_eq!(ledger.active_count(), 1);
        ledger.mark_inactive(&TurnKey::new("thread", "b"));
        assert!(ledger.active_on_thread("thread").is_none());
    }

    #[test]
    fn a_started_turn_claims_the_oldest_pending_prompt_for_its_thread() {
        let mut ledger = TurnLedger::default();
        ledger.insert_pending("1:2".to_owned(), pending("thread", 2.0, 1));
        ledger.insert_pending("1:1".to_owned(), pending("thread", 1.0, 1));
        ledger.insert_pending("1:3".to_owned(), pending("other", 0.5, 1));

        let key = TurnKey::new("thread", "turn");
        ledger.note_started(&key, 9.0);

        assert_eq!(
            ledger
                .context(&key)
                .map(|context| context.prompt_preview.as_str()),
            Some("prompt 1")
        );
        assert!(ledger.pending_start("1:1").is_none());
        assert!(ledger.pending_start("1:2").is_some());
        assert!(ledger.pending_start("1:3").is_some());
    }
}
