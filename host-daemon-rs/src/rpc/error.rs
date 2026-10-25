use serde_json::{Value, json};

pub(crate) const RETRY_AFTER_MS: u64 = 2_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RpcCode {
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    Internal,
    Capacity,
    ServerBusy,
    Unavailable,
    Conflict,
    CallEnded,
    Other(i64),
}

impl RpcCode {
    pub(crate) const fn value(self) -> i64 {
        match self {
            Self::ParseError => -32700,
            Self::InvalidRequest => -32600,
            Self::MethodNotFound => -32601,
            Self::InvalidParams => -32602,
            Self::Internal => -32603,
            Self::Capacity => -32001,
            Self::ServerBusy => -32002,
            Self::Unavailable => -32003,
            Self::Conflict => -32009,
            Self::CallEnded => -32010,
            Self::Other(code) => code,
        }
    }
}

impl From<i64> for RpcCode {
    fn from(code: i64) -> Self {
        [
            Self::ParseError,
            Self::InvalidRequest,
            Self::MethodNotFound,
            Self::InvalidParams,
            Self::Internal,
            Self::Capacity,
            Self::ServerBusy,
            Self::Unavailable,
            Self::Conflict,
            Self::CallEnded,
        ]
        .into_iter()
        .find(|known| known.value() == code)
        .unwrap_or(Self::Other(code))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum ErrorKind {
    TurnNotRunning {
        thread_id: String,
        turn_id: Option<String>,
    },
    CompactionDeliveryUncertain {
        thread_id: String,
    },
    AutomationUnavailable {
        authority: Option<String>,
    },
    AutomationAcknowledgementUnknown {
        authority: Option<String>,
        request_id: Option<String>,
    },
    HistoryCursorInvalid,
    HistoryPageTooLarge {
        actual_bytes: usize,
        limit_bytes: usize,
    },
    ConversationBusy {
        retry_after_ms: u64,
    },
    QueueUnsupported,
    QueueChangeUncertain {
        thread_id: String,
    },
    ProviderUnresponsive,
    InputDeliveryUncertain,
    RequestTimedOut {
        limit_ms: u64,
    },
    RequestCancelled,
    ProviderUnavailable {
        provider: &'static str,
        reason: String,
        retryable: bool,
    },
}

impl ErrorKind {
    const fn name(&self) -> &'static str {
        match self {
            Self::TurnNotRunning { .. } => "turnNotRunning",
            Self::CompactionDeliveryUncertain { .. } => "compactionDeliveryUncertain",
            Self::AutomationUnavailable { .. } => "automationUnavailable",
            Self::AutomationAcknowledgementUnknown { .. } => "automationAcknowledgementUnknown",
            Self::HistoryCursorInvalid => "historyCursorInvalid",
            Self::HistoryPageTooLarge { .. } => "historyPageTooLarge",
            Self::ConversationBusy { .. } => "conversationBusy",
            Self::QueueUnsupported => "queueUnsupported",
            Self::QueueChangeUncertain { .. } => "queueChangeUncertain",
            Self::ProviderUnresponsive => "providerUnresponsive",
            Self::InputDeliveryUncertain => "inputDeliveryUncertain",
            Self::RequestTimedOut { .. } => "requestTimedOut",
            Self::RequestCancelled => "requestCancelled",
            Self::ProviderUnavailable { .. } => "providerUnavailable",
        }
    }

    pub(crate) fn to_value(&self) -> Value {
        let mut data = match self {
            Self::TurnNotRunning { thread_id, turn_id } => {
                let mut data = json!({"threadId": thread_id});
                if let Some(turn_id) = turn_id {
                    data["turnId"] = json!(turn_id);
                }
                data
            }
            Self::CompactionDeliveryUncertain { thread_id }
            | Self::QueueChangeUncertain { thread_id } => json!({"threadId": thread_id}),
            Self::AutomationUnavailable { authority } => json!({"authority":authority}),
            Self::AutomationAcknowledgementUnknown {
                authority,
                request_id,
            } => json!({"authority":authority,"requestId":request_id}),
            Self::HistoryCursorInvalid | Self::QueueUnsupported | Self::RequestCancelled => {
                json!({})
            }
            Self::ProviderUnresponsive | Self::InputDeliveryUncertain => json!({}),
            Self::HistoryPageTooLarge {
                actual_bytes,
                limit_bytes,
            } => json!({"actualBytes": actual_bytes, "limitBytes": limit_bytes}),
            Self::ConversationBusy { retry_after_ms } => json!({"retryAfterMs": retry_after_ms}),
            Self::RequestTimedOut { limit_ms } => json!({"limitMs": limit_ms}),
            Self::ProviderUnavailable {
                provider, reason, ..
            } => {
                json!({"provider": provider, "reason": reason})
            }
        };
        data["kind"] = json!(self.name());
        data["retryable"] = json!(matches!(
            self,
            Self::ConversationBusy { .. }
                | Self::RequestTimedOut { .. }
                | Self::AutomationUnavailable { .. }
                | Self::AutomationAcknowledgementUnknown { .. }
                | Self::ProviderUnavailable {
                    retryable: true,
                    ..
                }
        ));
        data
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum RpcData {
    None,
    Capacity,
    ResourceCapacity {
        resource: &'static str,
    },
    SubscriptionCapacity {
        limit: usize,
    },
    ByteCapacity {
        resource: &'static str,
        actual_bytes: usize,
        limit: usize,
    },
    RetryAfterMs(u64),
    MetadataConflict(Value),
    VoiceCallEnded,
    Kind(ErrorKind),
    Raw(Value),
}

impl RpcData {
    fn to_value(&self) -> Option<Value> {
        match self {
            Self::None => None,
            Self::Capacity => Some(json!({"kind": "capacity", "retryable": true})),
            Self::ResourceCapacity { resource } => {
                Some(json!({"kind": "capacity", "retryable": true, "resource": resource}))
            }
            Self::SubscriptionCapacity { limit } => Some(
                json!({"kind":"capacity", "retryable":false,"resource":"conversation subscriptions","limit":limit}),
            ),
            Self::ByteCapacity {
                resource,
                actual_bytes,
                limit,
            } => Some(json!({"kind":"capacity",
                "retryable":false,"resource":resource,"actualBytes":actual_bytes,"limit":limit})),
            Self::RetryAfterMs(milliseconds) => Some(json!({"retryAfterMs": milliseconds})),
            Self::MetadataConflict(current) => {
                Some(json!({"kind": "metadataConflict", "retryable": false, "current": current}))
            }
            Self::VoiceCallEnded => Some(json!({"kind": "voiceCallEnded", "retryable": false})),
            Self::Kind(kind) => Some(kind.to_value()),
            Self::Raw(data) => Some(data.clone()),
        }
    }

    fn kind(&self) -> Option<&'static str> {
        match self {
            Self::Capacity
            | Self::ResourceCapacity { .. }
            | Self::SubscriptionCapacity { .. }
            | Self::ByteCapacity { .. } => Some("capacity"),
            Self::MetadataConflict(_) => Some("metadataConflict"),
            Self::VoiceCallEnded => Some("voiceCallEnded"),
            Self::Kind(kind) => Some(kind.name()),
            Self::None | Self::RetryAfterMs(_) | Self::Raw(_) => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct RpcError {
    pub(crate) code: RpcCode,
    pub(crate) message: String,
    pub(crate) data: RpcData,
}

pub(crate) type RpcResult = std::result::Result<Value, RpcError>;

impl RpcError {
    pub(crate) fn new(code: impl Into<RpcCode>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            data: RpcData::None,
        }
    }

    pub(crate) fn with_data(mut self, data: RpcData) -> Self {
        self.data = data;
        self
    }

    pub(crate) fn capacity() -> Self {
        Self::new(
            RpcCode::Capacity,
            "Gateway request capacity reached. Retry after current work finishes.",
        )
        .with_data(RpcData::Capacity)
    }

    pub(crate) fn turn_not_running(
        message: impl Into<String>,
        thread_id: &str,
        turn_id: Option<&str>,
    ) -> Self {
        Self::new(RpcCode::InvalidRequest, message).with_data(RpcData::Kind(
            ErrorKind::TurnNotRunning {
                thread_id: thread_id.to_owned(),
                turn_id: turn_id.map(str::to_owned),
            },
        ))
    }

    pub(crate) fn queue_unsupported() -> Self {
        Self::new(
            RpcCode::MethodNotFound,
            "Queued messages are not supported in Claude conversations",
        )
        .with_data(RpcData::Kind(ErrorKind::QueueUnsupported))
    }

    pub(crate) fn queue_change_uncertain(thread_id: &str, cause: &anyhow::Error) -> Self {
        Self::new(
            RpcCode::Unavailable,
            format!(
                "The queue change could not be confirmed; refresh this conversation before retrying: {cause:#}"
            ),
        )
        .with_data(RpcData::Kind(ErrorKind::QueueChangeUncertain {
            thread_id: thread_id.to_owned(),
        }))
    }

    pub(crate) fn request_timed_out(limit: std::time::Duration) -> Self {
        Self::new(
            RpcCode::Unavailable,
            format!(
                "The gateway could not finish this read within {} s; retry it",
                limit.as_secs()
            ),
        )
        .with_data(RpcData::Kind(ErrorKind::RequestTimedOut {
            limit_ms: u64::try_from(limit.as_millis()).unwrap_or(u64::MAX),
        }))
    }

    pub(crate) fn draining() -> Self {
        Self::new(
            RpcCode::ServerBusy,
            "Gateway is restarting; reconnect and try again",
        )
        .with_data(RpcData::RetryAfterMs(RETRY_AFTER_MS))
    }

    pub(crate) fn from_wire(error: &Value) -> Self {
        Self {
            code: RpcCode::from(error["code"].as_i64().unwrap_or(RpcCode::Internal.value())),
            message: error["message"].as_str().unwrap_or_default().to_owned(),
            data: error
                .get("data")
                .cloned()
                .map_or(RpcData::None, RpcData::Raw),
        }
    }

    pub(crate) fn kind(&self) -> Option<&'static str> {
        self.data.kind()
    }

    pub(crate) fn response(&self, id: &Value) -> Value {
        let mut error = json!({"code": self.code.value(), "message": self.message});
        if let Some(data) = self.data.to_value() {
            error["data"] = data;
        }
        json!({"id": id, "error": error})
    }
}

impl From<anyhow::Error> for RpcError {
    fn from(error: anyhow::Error) -> Self {
        CodexUnavailable::find(&error)
            .unwrap_or_else(|| Self::new(RpcCode::Internal, error.to_string()))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CodexUnavailable {
    pub(crate) reason: String,
    pub(crate) retryable: bool,
}

impl CodexUnavailable {
    pub(crate) fn find(error: &anyhow::Error) -> Option<RpcError> {
        error.downcast_ref::<Self>().cloned().map(RpcError::from)
    }
}

impl From<CodexUnavailable> for RpcError {
    fn from(CodexUnavailable { reason, retryable }: CodexUnavailable) -> Self {
        Self::new(
            RpcCode::Unavailable,
            format!("Codex is unavailable: {reason}"),
        )
        .with_data(RpcData::Kind(ErrorKind::ProviderUnavailable {
            provider: "codex",
            reason,
            retryable,
        }))
    }
}

impl std::fmt::Display for CodexUnavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.reason)
    }
}

impl std::error::Error for CodexUnavailable {}

impl From<(i64, String)> for RpcError {
    fn from((code, message): (i64, String)) -> Self {
        Self::new(code, message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_named_code_round_trips_and_unknown_codes_are_kept() {
        for code in [
            RpcCode::ParseError,
            RpcCode::InvalidRequest,
            RpcCode::MethodNotFound,
            RpcCode::InvalidParams,
            RpcCode::Internal,
            RpcCode::Capacity,
            RpcCode::ServerBusy,
            RpcCode::Unavailable,
            RpcCode::Conflict,
            RpcCode::CallEnded,
        ] {
            assert_eq!(RpcCode::from(code.value()), code);
        }
        assert_eq!(RpcCode::from(-32099), RpcCode::Other(-32099));
        assert_eq!(RpcCode::Other(7).value(), 7);
    }

    #[test]
    fn responses_keep_the_emitted_wire_shapes() {
        assert_eq!(
            RpcError::capacity().response(&json!(4)),
            json!({"id": 4, "error": {
                "code": -32001,
                "message": "Gateway request capacity reached. Retry after current work finishes.",
                "data": {"kind": "capacity", "retryable": true}
            }})
        );
        assert_eq!(
            RpcError::draining().response(&json!("a")),
            json!({"id": "a", "error": {
                "code": -32002,
                "message": "Gateway is restarting; reconnect and try again",
                "data": {"retryAfterMs": 2000}
            }})
        );
        assert_eq!(
            RpcError::new(RpcCode::InvalidParams, "cwd is required").response(&Value::Null),
            json!({"id": null, "error": {"code": -32602, "message": "cwd is required"}})
        );
        assert_eq!(
            RpcError::new(RpcCode::CallEnded, "ended")
                .with_data(RpcData::VoiceCallEnded)
                .response(&json!(2)),
            json!({"id": 2, "error": {
                "code": -32010,
                "message": "ended",
                "data": {"kind": "voiceCallEnded", "retryable": false}
            }})
        );
        assert_eq!(
            RpcError::new(RpcCode::Conflict, "changed")
                .with_data(RpcData::MetadataConflict(json!({"revision": 2})))
                .response(&json!(1))["error"]["data"],
            json!({"kind": "metadataConflict", "retryable": false, "current": {"revision": 2}})
        );
    }

    #[test]
    fn error_kinds_match_the_shared_protocol_fixtures() {
        let cases = [
            (
                RpcError::turn_not_running("no active turn to steer", "thread-1", Some("turn-1")),
                21,
                include_str!("../../../protocol-fixtures/errors/turn-not-running.json"),
            ),
            (
                RpcError::new(
                    RpcCode::InvalidRequest,
                    "invalid cursor: anchor turn is no longer present",
                )
                .with_data(RpcData::Kind(ErrorKind::HistoryCursorInvalid)),
                22,
                include_str!("../../../protocol-fixtures/errors/history-cursor-invalid.json"),
            ),
            (
                RpcError::new(
                    RpcCode::Unavailable,
                    "This conversation has a pending command; retry after it finishes",
                )
                .with_data(RpcData::Kind(ErrorKind::ConversationBusy {
                    retry_after_ms: RETRY_AFTER_MS,
                })),
                25,
                include_str!("../../../protocol-fixtures/errors/conversation-busy.json"),
            ),
            (
                RpcError::queue_change_uncertain(
                    "thread-1",
                    &anyhow::anyhow!("Codex did not answer the queued message change"),
                ),
                27,
                include_str!("../../../protocol-fixtures/errors/queue-change-uncertain.json"),
            ),
            (
                RpcError::new(
                    RpcCode::Unavailable,
                    "Claude has not read its input for 10 s, so delivery is unconfirmed; the input stays queued and reaches Claude if it resumes. A macOS permission prompt on the host can cause this",
                )
                .with_data(RpcData::Kind(ErrorKind::InputDeliveryUncertain)),
                28,
                include_str!("../../../protocol-fixtures/errors/input-delivery-uncertain.json"),
            ),
            (
                CodexUnavailable {
                    reason: "Codex sign-in needed on mac-mini".into(),
                    retryable: false,
                }
                .into(),
                41,
                include_str!("../../../protocol-fixtures/errors/provider-unavailable.json"),
            ),
        ];
        for (error, id, fixture) in cases {
            assert_eq!(
                error.response(&json!(id)),
                serde_json::from_str::<Value>(fixture).expect("fixture json")
            );
        }
        assert_eq!(
            RpcError::queue_unsupported().response(&json!(26)),
            json!({"id": 26, "error": {
                "code": -32601,
                "message": "Queued messages are not supported in Claude conversations",
                "data": {"kind": "queueUnsupported", "retryable": false}
            }})
        );
        assert_eq!(
            RpcError::turn_not_running("gone", "thread-1", None).response(&Value::Null)["error"]["data"],
            json!({"kind": "turnNotRunning", "retryable": false, "threadId": "thread-1"})
        );
    }

    #[test]
    fn an_unreachable_codex_keeps_its_kind_and_retryability_through_context() {
        let unavailable = CodexUnavailable {
            reason: "Codex app-server is not running".into(),
            retryable: true,
        };
        let error = anyhow::Error::new(unavailable.clone()).context("model list failed");
        let error = RpcError::from(error);
        assert_eq!(error, RpcError::from(unavailable));
        assert_eq!(
            error.response(&Value::Null)["error"]["data"]["retryable"],
            json!(true)
        );
    }

    #[test]
    fn a_native_error_keeps_its_code_message_and_data() {
        let error = RpcError::from_wire(
            &json!({"code": -32003, "message": "moved", "data": {"continuedIn": "acct"}}),
        );
        assert_eq!(error.code, RpcCode::Unavailable);
        assert_eq!(error.kind(), None);
        assert_eq!(
            error.response(&json!(9))["error"]["data"],
            json!({"continuedIn": "acct"})
        );
    }
}
