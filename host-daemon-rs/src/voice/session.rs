use std::sync::{Mutex, MutexGuard};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use tokio::sync::oneshot;

use crate::observability::voice::VoiceLog;
use crate::time::unix_seconds;
use crate::voice::farewell::FarewellWatch;
use crate::voice::handoff::VoiceDelegations;
use crate::voice::shadows::ShadowPool;

/// Grace window after a requested voice stop during which the transcript-tail
/// flush handoff can still arrive and dispatch to the executor.
pub(crate) const VOICE_STOP_TAIL_GRACE_SECONDS: u64 = 5;
pub(crate) const VOICE_WATCHDOG_TICK_SECONDS: u64 = 15;
/// Consecutive watchdog ticks a bound turn may be missing from the executor
/// before its delegation is force-completed as orphaned. Two ticks tolerate an
/// in-flight `turn/completed` notification.
pub(crate) const VOICE_WATCHDOG_ORPHAN_TICKS: u32 = 2;
pub(crate) const VOICE_MODE_GREETING: &str = "The user just started Voice Mode. Greet them in at most \
    five casual words, like a friend picking up, and vary it every call, for example \
    \"Hey! What's up?\" or \"Yo, what do you need?\". Greet by time of day only \
    if you know it, then wait for them to speak.";
pub(crate) const VOICE_MODE_PROMPT: &str = include_str!("../../prompts/voice-mode.md");

pub(crate) fn voice_mode_greeting(user_name: Option<&str>) -> String {
    match user_name {
        Some(name) => format!(
            "{VOICE_MODE_GREETING} The user's name is {name}; you can greet them with \
             \"Hey {name}! What's up?\"."
        ),
        None => VOICE_MODE_GREETING.to_owned(),
    }
}

pub(crate) fn voice_mode_prompt(user_name: Option<&str>) -> String {
    match user_name {
        Some(name) => format!("{VOICE_MODE_PROMPT}\nThe user's name is {name}.\n"),
        None => VOICE_MODE_PROMPT.to_owned(),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VoiceSessionOrigin {
    VoiceMode,
    AgentCall,
}

/// Legacy start-rejection text for automatic reconnect of a terminally ended
/// call. VoiceCall matches it to end quietly, so its wire value stays stable.
pub(crate) const VOICE_CALL_AGENT_ENDED_ERROR: &str = "voice call already ended by the agent";

#[derive(Debug)]
pub(crate) struct VoiceCallEnded;
impl std::fmt::Display for VoiceCallEnded {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(VOICE_CALL_AGENT_ENDED_ERROR)
    }
}
impl std::error::Error for VoiceCallEnded {}

#[derive(Debug, Clone)]
pub(crate) struct VoiceSession {
    pub(crate) owner_client_id: u64,
    pub(crate) realtime_session_id: String,
    pub(crate) realtime_thread_id: String,
    pub(crate) conversation_thread_id: String,
    pub(crate) model: String,
    pub(crate) effort: Option<String>,
    pub(crate) cwd: String,
    pub(crate) uses_external_executor: bool,
    pub(crate) delegations: VoiceDelegations,
    pub(crate) tail_flush_dispatched: bool,
    pub(crate) greeted: bool,
    pub(crate) farewell: Option<FarewellWatch>,
    pub(crate) started_at_unix_seconds: f64,
    pub(crate) log: Option<VoiceLog>,
}

impl VoiceSession {
    pub(crate) fn log_event(&self, event: &str, fields: Value) {
        if let Some(log) = self.log.as_ref() {
            log.event(event, fields);
        }
    }

    pub(crate) fn log_start(&self, voice: &str, initial_item_count: usize) {
        self.log_event(
            "session/start",
            json!({
                "realtimeThreadId": self.realtime_thread_id,
                "conversationThreadId": self.conversation_thread_id,
                "provider": if self.uses_external_executor { "claude" } else { "codex" },
                "model": self.model,
                "effort": self.effort,
                "cwd": self.cwd,
                "voice": voice,
                "realtimeSessionId": self.realtime_session_id,
                "initialItemCount": initial_item_count,
            }),
        );
    }

    /// Emits the closing summary. Called exactly once, when the session state
    /// is taken out of the gateway.
    pub(crate) fn close_log(&self, reason: &str) {
        self.log_event(
            "session/summary",
            json!({
                "reason": reason,
                "durationSeconds": unix_seconds() - self.started_at_unix_seconds,
                "delegationsRequested": self.delegations.requested_count,
                "delegationsCompleted": self.delegations.completed_count,
                "delegationsSuperseded": self.delegations.superseded_count,
                "delegationsFailed": self.delegations.failed_count,
                "synthesizedAppends": self.delegations.synthesized_append_count,
                "tailFlushDispatched": self.tail_flush_dispatched,
            }),
        );
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VoiceSessionOwner {
    pub(crate) client_id: u64,
    pub(crate) realtime_session_id: String,
}

pub(crate) struct StartAdmission {
    pub(crate) preempted: Option<VoiceSessionOwner>,
    pub(crate) previous_session: Option<VoiceSession>,
    pub(crate) predecessor_closed: Option<oneshot::Receiver<()>>,
    pub(crate) previous_realtime_thread_id: Option<String>,
}

pub(crate) enum StopRequest {
    Ignored {
        owner_client_id: Option<u64>,
    },
    Released {
        owner: VoiceSessionOwner,
        realtime_thread_id: Option<String>,
    },
}

pub(crate) struct EndedCall {
    pub(crate) owner: VoiceSessionOwner,
    pub(crate) realtime_thread_id: Option<String>,
}

pub(crate) struct Hangup {
    pub(crate) realtime_session_id: String,
    pub(crate) realtime_thread_id: String,
}

#[derive(Debug)]
struct VoicePredecessor {
    owner: VoiceSessionOwner,
    realtime_thread_id: String,
    automatic_reclaim: bool,
    closed: Option<oneshot::Sender<()>>,
}

impl VoicePredecessor {
    fn retiring(session: &VoiceSession) -> Self {
        Self {
            owner: VoiceSessionOwner {
                client_id: session.owner_client_id,
                realtime_session_id: session.realtime_session_id.clone(),
            },
            realtime_thread_id: session.realtime_thread_id.clone(),
            automatic_reclaim: false,
            closed: None,
        }
    }
}

pub(crate) enum VoiceTransportEnd<'a> {
    Error,
    Closed(Option<&'a str>),
    ProviderClosed,
}

impl VoiceTransportEnd<'_> {
    fn permits_reclaim(&self) -> bool {
        matches!(self, Self::Closed(Some("requested" | "transport_closed")))
    }
}

#[derive(Debug, Default)]
enum VoicePhase {
    #[default]
    Idle,
    Starting {
        owner: VoiceSessionOwner,
        predecessor: Option<VoicePredecessor>,
    },
    Active {
        owner: VoiceSessionOwner,
        session: VoiceSession,
    },
    /// Set on a requested stop: the session stays alive briefly so the
    /// transcript-tail flush handoff can still reach the executor.
    Draining {
        session: VoiceSession,
        transport_closed: bool,
    },
    Retiring(VoicePredecessor),
}

impl VoicePhase {
    fn owner(&self) -> Option<&VoiceSessionOwner> {
        match self {
            Self::Starting { owner, .. } | Self::Active { owner, .. } => Some(owner),
            Self::Idle | Self::Retiring(_) | Self::Draining { .. } => None,
        }
    }

    fn session(&self) -> Option<&VoiceSession> {
        match self {
            Self::Active { session, .. } | Self::Draining { session, .. } => Some(session),
            Self::Idle | Self::Retiring(_) | Self::Starting { .. } => None,
        }
    }

    fn session_mut(&mut self) -> Option<&mut VoiceSession> {
        match self {
            Self::Active { session, .. } | Self::Draining { session, .. } => Some(session),
            Self::Idle | Self::Retiring(_) | Self::Starting { .. } => None,
        }
    }

    fn live_session(&self) -> Option<&VoiceSession> {
        match self {
            Self::Active { session, .. } => Some(session),
            Self::Idle | Self::Retiring(_) | Self::Starting { .. } | Self::Draining { .. } => None,
        }
    }

    fn live_session_mut(&mut self) -> Option<&mut VoiceSession> {
        match self {
            Self::Active { session, .. } => Some(session),
            Self::Idle | Self::Retiring(_) | Self::Starting { .. } | Self::Draining { .. } => None,
        }
    }

    fn is_draining(&self) -> bool {
        matches!(self, Self::Draining { .. })
    }

    fn into_session(self) -> Option<VoiceSession> {
        match self {
            Self::Active { session, .. } | Self::Draining { session, .. } => Some(session),
            Self::Idle | Self::Retiring(_) | Self::Starting { .. } => None,
        }
    }

    fn drain(&mut self, reason: &'static str) -> Option<String> {
        match std::mem::take(self) {
            Self::Active { session, .. } => {
                session.log_event("session/stop", json!({ "reason": reason }));
                let realtime_thread_id = session.realtime_thread_id.clone();
                *self = Self::Draining {
                    session,
                    transport_closed: false,
                };
                Some(realtime_thread_id)
            }
            Self::Starting {
                predecessor: Some(mut previous),
                ..
            } => {
                previous.closed = None;
                *self = Self::Retiring(previous);
                None
            }
            phase @ (Self::Draining { .. } | Self::Retiring(_)) => {
                *self = phase;
                None
            }
            Self::Idle | Self::Starting { .. } => None,
        }
    }
}

#[derive(Debug, Default)]
enum VoiceReclaimAuthority {
    #[default]
    Fresh,
    Reclaimable(String),
    Revoked(String),
}

impl VoiceReclaimAuthority {
    fn revoke(&mut self, realtime_session_id: &str) {
        if matches!(self, Self::Reclaimable(current) if current.as_str() == realtime_session_id) {
            *self = Self::Revoked(realtime_session_id.to_string());
        }
    }
}

#[derive(Debug, Default)]
struct VoiceState {
    phase: VoicePhase,
    reclaim_authority: VoiceReclaimAuthority,
}

/// Proof that the caller holds the voice transition order: starting,
/// replacing, stopping and publishing settings for voice happen one at a time.
pub(crate) struct VoiceTransition<'a> {
    voice: &'a VoiceCoordinator,
    _guard: tokio::sync::MutexGuard<'a, ()>,
}

impl Drop for VoiceTransition<'_> {
    fn drop(&mut self) {
        let mut state = self.voice.state();
        if matches!(state.phase, VoicePhase::Starting { .. }) {
            state.phase.drain("startup retired");
        }
    }
}

#[derive(Debug, Default)]
pub(crate) struct VoiceCoordinator {
    transition: tokio::sync::Mutex<()>,
    state: Mutex<VoiceState>,
    pub(crate) shadows: ShadowPool,
}

impl VoiceCoordinator {
    pub(crate) async fn transition(&self) -> VoiceTransition<'_> {
        VoiceTransition {
            voice: self,
            _guard: self.transition.lock().await,
        }
    }

    fn state(&self) -> MutexGuard<'_, VoiceState> {
        self.state.lock().expect("voice state poisoned")
    }

    pub(crate) fn begin_start(
        &self,
        _transition: &VoiceTransition<'_>,
        client_id: u64,
        realtime_session_id: &str,
        replace_existing_session: bool,
    ) -> Result<StartAdmission> {
        let mut state = self.state();
        if !replace_existing_session {
            match &state.reclaim_authority {
                VoiceReclaimAuthority::Fresh => {}
                VoiceReclaimAuthority::Reclaimable(current) if current == realtime_session_id => {}
                VoiceReclaimAuthority::Revoked(current) if current == realtime_session_id => {
                    return Err(VoiceCallEnded.into());
                }
                _ => {
                    return Err(anyhow!(
                        "automatic reconnect superseded by a newer voice call"
                    ));
                }
            }
        }
        let previous = match &state.phase {
            VoicePhase::Draining {
                transport_closed: true,
                ..
            } => None,
            VoicePhase::Active { session, .. } | VoicePhase::Draining { session, .. } => Some((
                VoiceSessionOwner {
                    client_id: session.owner_client_id,
                    realtime_session_id: session.realtime_session_id.clone(),
                },
                session.realtime_thread_id.clone(),
            )),
            VoicePhase::Retiring(previous)
            | VoicePhase::Starting {
                predecessor: Some(previous),
                ..
            } => Some((previous.owner.clone(), previous.realtime_thread_id.clone())),
            _ => None,
        };
        let (predecessor, predecessor_closed) = match previous {
            Some((owner, realtime_thread_id)) => {
                let (closed, receiver) = oneshot::channel();
                let automatic_reclaim =
                    !replace_existing_session && owner.realtime_session_id == realtime_session_id;
                (
                    Some(VoicePredecessor {
                        owner,
                        realtime_thread_id,
                        automatic_reclaim,
                        closed: Some(closed),
                    }),
                    Some(receiver),
                )
            }
            None => (None, None),
        };
        let previous_realtime_thread_id = predecessor
            .as_ref()
            .map(|previous| previous.realtime_thread_id.clone());
        let starting = VoicePhase::Starting {
            owner: VoiceSessionOwner {
                client_id,
                realtime_session_id: realtime_session_id.to_string(),
            },
            predecessor,
        };
        let (previous_owner, previous_session) = match std::mem::replace(&mut state.phase, starting)
        {
            VoicePhase::Idle | VoicePhase::Retiring(_) => (None, None),
            VoicePhase::Starting { owner, .. } => (Some(owner), None),
            VoicePhase::Active { owner, session } => (Some(owner), Some(session)),
            VoicePhase::Draining { session, .. } => (None, Some(session)),
        };
        state.reclaim_authority =
            VoiceReclaimAuthority::Reclaimable(realtime_session_id.to_string());
        Ok(StartAdmission {
            preempted: previous_owner.filter(|previous| previous.client_id != client_id),
            previous_session,
            predecessor_closed,
            previous_realtime_thread_id,
        })
    }

    pub(crate) fn install(&self, _transition: &VoiceTransition<'_>, session: VoiceSession) -> bool {
        let mut state = self.state();
        match std::mem::take(&mut state.phase) {
            VoicePhase::Starting {
                owner,
                predecessor: None,
            } if owner.client_id == session.owner_client_id
                && owner.realtime_session_id == session.realtime_session_id =>
            {
                state.phase = VoicePhase::Active { owner, session };
                true
            }
            other => {
                state.phase = other;
                drop(state);
                session.close_log("superseded during start");
                false
            }
        }
    }

    pub(crate) fn owns_start(&self, client_id: u64, realtime_session_id: &str) -> bool {
        self.state().phase.owner().is_some_and(|owner| {
            owner.client_id == client_id && owner.realtime_session_id == realtime_session_id
        })
    }

    pub(crate) fn clear(
        &self,
        client_id: u64,
        realtime_thread_id: Option<&str>,
    ) -> Option<VoiceSession> {
        let mut state = self.state();
        let matches = match &state.phase {
            VoicePhase::Idle | VoicePhase::Retiring(_) => false,
            VoicePhase::Starting { owner, .. } => {
                realtime_thread_id.is_none() && owner.client_id == client_id
            }
            VoicePhase::Active { session, .. } | VoicePhase::Draining { session, .. } => {
                session.owner_client_id == client_id
                    && realtime_thread_id
                        .is_none_or(|thread_id| session.realtime_thread_id == thread_id)
            }
        };
        if !matches {
            return None;
        }
        let phase = std::mem::take(&mut state.phase);
        match phase {
            VoicePhase::Starting {
                predecessor: Some(mut previous),
                ..
            } => {
                previous.closed = None;
                state.phase = VoicePhase::Retiring(previous);
                None
            }
            phase => phase.into_session(),
        }
    }

    pub(crate) fn begin_stop(
        &self,
        _transition: &VoiceTransition<'_>,
        client_id: u64,
    ) -> StopRequest {
        let mut state = self.state();
        let owner = match state.phase.owner() {
            Some(existing) if existing.client_id != client_id => {
                return StopRequest::Ignored {
                    owner_client_id: Some(existing.client_id),
                };
            }
            Some(owner) => owner.clone(),
            None => {
                return StopRequest::Ignored {
                    owner_client_id: None,
                };
            }
        };
        StopRequest::Released {
            owner,
            realtime_thread_id: state.phase.drain("requested"),
        }
    }

    pub(crate) fn begin_end_call(
        &self,
        _transition: &VoiceTransition<'_>,
        call_id: &str,
    ) -> Option<EndedCall> {
        let mut state = self.state();
        let owner = state
            .phase
            .owner()
            .filter(|owner| owner.realtime_session_id == call_id)
            .cloned()?;
        state.reclaim_authority.revoke(call_id);
        Some(EndedCall {
            owner,
            realtime_thread_id: state.phase.drain("agent call ended"),
        })
    }

    pub(crate) fn end_realtime_thread(
        &self,
        realtime_thread_id: &str,
        end: VoiceTransportEnd<'_>,
    ) -> Option<(VoiceSessionOwner, Option<VoiceSession>)> {
        let mut state = self.state();
        let owner = match &mut state.phase {
            VoicePhase::Starting { owner, predecessor } => {
                let previous = predecessor
                    .as_ref()
                    .filter(|previous| previous.realtime_thread_id == realtime_thread_id)?;
                if !previous.automatic_reclaim || end.permits_reclaim() {
                    if matches!(
                        end,
                        VoiceTransportEnd::Closed(_) | VoiceTransportEnd::ProviderClosed
                    ) && let Some(previous) = predecessor.take()
                        && let Some(closed) = previous.closed
                    {
                        let _ = closed.send(());
                    }
                    return None;
                }
                owner.clone()
            }
            // A requested stop drains instead: the finalize task owns
            // removal so the tail-flush handoff can still dispatch.
            VoicePhase::Draining {
                session,
                transport_closed,
            } if session.realtime_thread_id == realtime_thread_id && end.permits_reclaim() => {
                *transport_closed = true;
                return None;
            }
            VoicePhase::Retiring(previous) if previous.realtime_thread_id == realtime_thread_id => {
                if !end.permits_reclaim() {
                    let previous_session_id = previous.owner.realtime_session_id.clone();
                    state.reclaim_authority.revoke(&previous_session_id);
                }
                if matches!(end, VoiceTransportEnd::Error) {
                    return None;
                }
                let VoicePhase::Retiring(previous) = std::mem::take(&mut state.phase) else {
                    unreachable!();
                };
                return Some((previous.owner, None));
            }
            VoicePhase::Active { session, .. } | VoicePhase::Draining { session, .. }
                if session.realtime_thread_id == realtime_thread_id =>
            {
                VoiceSessionOwner {
                    client_id: session.owner_client_id,
                    realtime_session_id: session.realtime_session_id.clone(),
                }
            }
            _ => return None,
        };
        if !matches!(end, VoiceTransportEnd::Closed(Some("transport_closed"))) {
            state.reclaim_authority.revoke(&owner.realtime_session_id);
        }
        let session = match std::mem::take(&mut state.phase) {
            VoicePhase::Starting {
                predecessor: Some(mut previous),
                ..
            } if matches!(end, VoiceTransportEnd::Error) => {
                previous.closed = None;
                state.phase = VoicePhase::Retiring(previous);
                None
            }
            phase => phase.into_session(),
        };
        if matches!(end, VoiceTransportEnd::Error)
            && let Some(session) = session.as_ref()
        {
            state.phase = VoicePhase::Retiring(VoicePredecessor::retiring(session));
        }
        Some((owner, session))
    }

    pub(crate) fn begin_agent_hangup(
        &self,
        _transition: &VoiceTransition<'_>,
        conversation_thread_id: &str,
        provider_is_claude: bool,
    ) -> Option<Hangup> {
        self.hang_up("agent tool", |session| {
            session.conversation_thread_id == conversation_thread_id
                && session.uses_external_executor == provider_is_claude
        })
    }

    pub(crate) fn begin_farewell_hangup(
        &self,
        _transition: &VoiceTransition<'_>,
        realtime_thread_id: &str,
        now: tokio::time::Instant,
    ) -> Option<Hangup> {
        self.hang_up("farewell", |session| {
            session.realtime_thread_id == realtime_thread_id
                && session
                    .farewell
                    .as_ref()
                    .and_then(FarewellWatch::close_at)
                    .is_some_and(|close_at| close_at <= now)
        })
    }

    fn hang_up(
        &self,
        reason: &'static str,
        accepts: impl FnOnce(&VoiceSession) -> bool,
    ) -> Option<Hangup> {
        let mut state = self.state();
        let hangup = state
            .phase
            .live_session()
            .filter(|session| accepts(session))
            .map(|session| Hangup {
                realtime_session_id: session.realtime_session_id.clone(),
                realtime_thread_id: session.realtime_thread_id.clone(),
            })?;
        state.reclaim_authority.revoke(&hangup.realtime_session_id);
        state.phase.drain(reason);
        Some(hangup)
    }

    pub(crate) fn finish_draining(&self, realtime_thread_id: &str) -> Option<VoiceSession> {
        let mut state = self.state();
        if !matches!(
            &state.phase,
            VoicePhase::Draining { session, .. } if session.realtime_thread_id == realtime_thread_id
        ) {
            return None;
        }
        let VoicePhase::Draining {
            session,
            transport_closed,
        } = std::mem::take(&mut state.phase)
        else {
            unreachable!();
        };
        if !transport_closed {
            state.phase = VoicePhase::Retiring(VoicePredecessor::retiring(&session));
        }
        Some(session)
    }

    pub(crate) fn take_for_shutdown(&self) -> Option<VoiceSession> {
        std::mem::take(&mut self.state().phase).into_session()
    }

    pub(crate) fn has_owner(&self) -> bool {
        self.state().phase.owner().is_some()
    }

    pub(crate) fn owner(&self) -> Option<VoiceSessionOwner> {
        self.state().phase.owner().cloned()
    }

    pub(crate) fn owner_client_of_realtime_thread(&self, realtime_thread_id: &str) -> Option<u64> {
        match &self.state().phase {
            VoicePhase::Starting {
                owner,
                predecessor: Some(previous),
            } if previous.realtime_thread_id == realtime_thread_id => Some(owner.client_id),
            VoicePhase::Retiring(previous) if previous.realtime_thread_id == realtime_thread_id => {
                Some(previous.owner.client_id)
            }
            phase => phase
                .session()
                .filter(|session| session.realtime_thread_id == realtime_thread_id)
                .map(|session| session.owner_client_id),
        }
    }

    pub(crate) fn is_media_owner(&self, client_id: u64, realtime_session_id: &str) -> bool {
        self.state().phase.session().is_some_and(|session| {
            session.owner_client_id == client_id
                && session.realtime_session_id == realtime_session_id
        })
    }

    pub(crate) fn live_realtime_thread(&self, realtime_session_id: &str) -> Option<String> {
        self.state()
            .phase
            .live_session()
            .filter(|session| session.realtime_session_id == realtime_session_id)
            .map(|session| session.realtime_thread_id.clone())
    }

    pub(crate) fn log_path(&self, realtime_session_id: &str) -> Option<String> {
        self.state()
            .phase
            .session()
            .filter(|session| session.realtime_session_id == realtime_session_id)
            .and_then(|session| session.log.as_ref())
            .map(|log| log.path.display().to_string())
    }

    pub(crate) fn with_realtime_thread<R>(
        &self,
        realtime_thread_id: &str,
        update: impl FnOnce(&mut VoiceSession) -> R,
    ) -> Option<R> {
        self.state()
            .phase
            .session_mut()
            .filter(|session| session.realtime_thread_id == realtime_thread_id)
            .map(update)
    }

    pub(crate) fn with_realtime_thread_draining<R>(
        &self,
        realtime_thread_id: &str,
        update: impl FnOnce(&mut VoiceSession, bool) -> R,
    ) -> Option<R> {
        let mut state = self.state();
        let draining = state.phase.is_draining();
        state
            .phase
            .session_mut()
            .filter(|session| session.realtime_thread_id == realtime_thread_id)
            .map(|session| update(session, draining))
    }

    pub(crate) fn with_live_realtime_thread<R>(
        &self,
        realtime_thread_id: &str,
        update: impl FnOnce(&mut VoiceSession) -> R,
    ) -> Option<R> {
        self.state()
            .phase
            .live_session_mut()
            .filter(|session| session.realtime_thread_id == realtime_thread_id)
            .map(update)
    }

    pub(crate) fn with_live_conversation<R>(
        &self,
        conversation_thread_id: &str,
        update: impl FnOnce(&mut VoiceSession) -> R,
    ) -> Option<R> {
        self.state()
            .phase
            .live_session_mut()
            .filter(|session| session.conversation_thread_id == conversation_thread_id)
            .map(update)
    }

    pub(crate) fn with_live_owned<R>(
        &self,
        client_id: u64,
        realtime_session_id: &str,
        update: impl FnOnce(&mut VoiceSession) -> R,
    ) -> Option<R> {
        self.state()
            .phase
            .live_session_mut()
            .filter(|session| {
                session.owner_client_id == client_id
                    && session.realtime_session_id == realtime_session_id
            })
            .map(update)
    }

    pub(crate) fn with_conversation<R>(
        &self,
        conversation_thread_id: &str,
        update: impl FnOnce(&mut VoiceSession) -> R,
    ) -> Option<R> {
        self.state()
            .phase
            .session_mut()
            .filter(|session| session.conversation_thread_id == conversation_thread_id)
            .map(update)
    }

    #[cfg(test)]
    pub(crate) fn ended_call(&self) -> Option<String> {
        match &self.state().reclaim_authority {
            VoiceReclaimAuthority::Revoked(current) => Some(current.clone()),
            _ => None,
        }
    }

    #[cfg(test)]
    pub(crate) fn session(&self) -> Option<VoiceSession> {
        self.state().phase.session().cloned()
    }

    #[cfg(test)]
    pub(crate) fn is_draining(&self) -> bool {
        self.state().phase.is_draining()
    }

    #[cfg(test)]
    pub(crate) fn drain_for_test(&self) {
        self.state().phase.drain("test");
    }

    #[cfg(test)]
    pub(crate) fn seed(&self, owner: Option<VoiceSessionOwner>, session: Option<VoiceSession>) {
        let phase = match (owner, session) {
            (None, None) => VoicePhase::Idle,
            (Some(owner), None) => VoicePhase::Starting {
                owner,
                predecessor: None,
            },
            (owner, Some(session)) => VoicePhase::Active {
                owner: owner.unwrap_or_else(|| VoiceSessionOwner {
                    client_id: session.owner_client_id,
                    realtime_session_id: session.realtime_session_id.clone(),
                }),
                session,
            },
        };
        let reclaim_authority = phase
            .owner()
            .map(|owner| &owner.realtime_session_id)
            .map(|current| VoiceReclaimAuthority::Reclaimable(current.clone()))
            .unwrap_or_default();
        *self.state() = VoiceState {
            phase,
            reclaim_authority,
        };
    }

    #[cfg(test)]
    pub(crate) fn seed_ended_call(&self, realtime_session_id: &str) {
        self.state().reclaim_authority =
            VoiceReclaimAuthority::Revoked(realtime_session_id.to_string());
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn voice_mode_personalizes_only_with_the_configured_name() {
        assert_eq!(super::voice_mode_prompt(None), super::VOICE_MODE_PROMPT);
        assert_eq!(super::voice_mode_greeting(None), super::VOICE_MODE_GREETING);
        assert!(
            super::voice_mode_prompt(Some("Maya Chen")).contains("The user's name is Maya Chen.")
        );
        assert!(super::voice_mode_greeting(Some("Maya Chen")).contains("Hey Maya Chen!"));
    }

    use super::*;

    fn session(
        client_id: u64,
        realtime_session_id: &str,
        realtime_thread_id: &str,
    ) -> VoiceSession {
        VoiceSession {
            owner_client_id: client_id,
            realtime_session_id: realtime_session_id.to_string(),
            realtime_thread_id: realtime_thread_id.to_string(),
            conversation_thread_id: "conversation".to_string(),
            model: "sonnet".to_string(),
            effort: None,
            cwd: "/tmp".to_string(),
            uses_external_executor: true,
            delegations: VoiceDelegations::new(),
            tail_flush_dispatched: false,
            greeted: false,
            farewell: None,
            started_at_unix_seconds: 0.0,
            log: None,
        }
    }

    #[tokio::test]
    async fn install_is_refused_once_the_start_was_cleared() {
        let voice = VoiceCoordinator::default();
        let transition = voice.transition().await;
        voice
            .begin_start(&transition, 1, "call-1", true)
            .expect("start admitted");
        assert!(voice.clear(1, None).is_none());

        assert!(!voice.install(&transition, session(1, "call-1", "thread-1")));
        assert!(matches!(voice.state().phase, VoicePhase::Idle));
    }

    #[tokio::test]
    async fn clear_naming_another_realtime_thread_keeps_the_active_call() {
        let voice = VoiceCoordinator::default();
        let transition = voice.transition().await;
        voice
            .begin_start(&transition, 1, "call-1", true)
            .expect("start admitted");
        assert!(voice.install(&transition, session(1, "call-1", "thread-1")));

        assert!(voice.clear(1, Some("stale-thread")).is_none());
        assert!(voice.has_owner());
        assert!(voice.live_realtime_thread("call-1").is_some());

        assert!(voice.clear(1, Some("thread-1")).is_some());
        assert!(matches!(voice.state().phase, VoicePhase::Idle));
    }

    #[tokio::test]
    async fn automatic_reclaim_only_reuses_the_latest_logical_call_while_idle() {
        for terminal in [true, false] {
            let voice = VoiceCoordinator::default();
            let transition = voice.transition().await;
            voice.begin_start(&transition, 1, "call-a", true).unwrap();
            assert!(voice.install(&transition, session(1, "call-a", "thread-a")));
            assert!(
                voice
                    .end_realtime_thread("thread-a", VoiceTransportEnd::ProviderClosed)
                    .is_some()
            );

            voice.begin_start(&transition, 2, "call-b", true).unwrap();
            assert!(voice.install(&transition, session(2, "call-b", "thread-b")));
            let end = if terminal {
                VoiceTransportEnd::ProviderClosed
            } else {
                VoiceTransportEnd::Closed(Some("transport_closed"))
            };
            assert!(voice.end_realtime_thread("thread-b", end).is_some());
            assert!(!voice.has_owner());
            assert!(voice.session().is_none());

            let stale = voice
                .begin_start(&transition, 1, "call-a", false)
                .err()
                .expect("a delayed reconnect cannot return to the older call");
            assert!(
                stale
                    .to_string()
                    .contains("superseded by a newer voice call")
            );
            if terminal {
                let ended = voice
                    .begin_start(&transition, 2, "call-b", false)
                    .err()
                    .expect("terminal closure revokes the latest call's reclaim authority");
                assert!(ended.is::<VoiceCallEnded>());
            } else {
                voice.begin_start(&transition, 3, "call-b", false).unwrap();
                assert!(voice.install(&transition, session(3, "call-b", "thread-b-recovered")));
            }
        }
    }

    #[tokio::test]
    async fn fresh_coordinator_admits_automatic_recovery_and_then_keeps_that_authority() {
        let voice = VoiceCoordinator::default();
        let transition = voice.transition().await;
        voice.begin_start(&transition, 1, "call-a", false).unwrap();
        assert!(voice.install(&transition, session(1, "call-a", "thread-a")));
        assert!(voice.clear(1, Some("thread-a")).is_some());
        assert!(voice.begin_start(&transition, 2, "call-b", false).is_err());
        voice.begin_start(&transition, 2, "call-a", false).unwrap();
        assert!(voice.install(&transition, session(2, "call-a", "thread-a-recovered")));
    }

    #[tokio::test]
    async fn cancelled_replacement_keeps_the_latest_admission_authoritative() {
        for closed_before_retry in [true, false] {
            let voice = VoiceCoordinator::default();
            {
                let transition = voice.transition().await;
                voice.begin_start(&transition, 1, "call-a", true).unwrap();
                assert!(voice.install(&transition, session(1, "call-a", "thread-a")));
                voice.begin_start(&transition, 2, "call-b", true).unwrap();
            }
            if closed_before_retry {
                assert!(
                    voice
                        .end_realtime_thread("thread-a", VoiceTransportEnd::ProviderClosed)
                        .is_some()
                );
            }
            let transition = voice.transition().await;
            assert!(voice.begin_start(&transition, 1, "call-a", false).is_err());
            let mut admission = voice.begin_start(&transition, 2, "call-b", false).unwrap();
            assert_eq!(admission.predecessor_closed.is_none(), closed_before_retry);
            if let Some(receipt) = admission.predecessor_closed.take() {
                assert!(!voice.install(&transition, session(2, "call-b", "thread-b")));
                assert!(
                    voice
                        .end_realtime_thread("thread-a", VoiceTransportEnd::ProviderClosed)
                        .is_none()
                );
                receipt.await.unwrap();
            }
            assert!(voice.install(&transition, session(2, "call-b", "thread-b")));
        }
    }
}
