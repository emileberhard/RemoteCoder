use std::time::Duration;

use anyhow::{Result, anyhow};
use serde_json::json;
use tracing::{error, info};

use crate::observability::journal::Journal;
use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::recovery::RecoveryStore;
use crate::runtime::transaction::RecoveryTransaction;

const CODEX_HANDOFF_TIMEOUT: Duration = Duration::from_secs(35);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CodexRestart {
    NotOwner,
    PreparedHandoff,
    Idle,
    Suspend,
}

impl CodexRestart {
    fn as_str(self) -> &'static str {
        match self {
            Self::NotOwner => "notOwner",
            Self::PreparedHandoff => "preparedHandoff",
            Self::Idle => "idle",
            Self::Suspend => "suspend",
        }
    }
}

pub(crate) async fn suspend_codex(
    codex: &CodexAppServer,
    store: Option<&RecoveryStore>,
    journal: &Journal,
    decision: CodexRestart,
) {
    journal.runtime("restart_codex", json!({ "decision": decision.as_str() }));
    let (CodexRestart::Suspend, Some(store)) = (decision, store) else {
        return;
    };
    let result = tokio::time::timeout(
        CODEX_HANDOFF_TIMEOUT,
        RecoveryTransaction::new(codex, store).prepare_handoff_for_shutdown(),
    )
    .await
    .unwrap_or_else(|_| {
        Err(anyhow!(
            "timed out after {} seconds; the next bootstrap recovers any persisted progress",
            CODEX_HANDOFF_TIMEOUT.as_secs()
        ))
    });
    report(result, journal);
}

fn report(result: Result<()>, journal: &Journal) {
    match result {
        Ok(()) => {
            info!("Codex work suspended for recovery by the replacement gateway");
            journal.runtime("restart_codex_suspended", json!({ "ok": true }));
        }
        Err(error) => {
            error!(error = %format!("{error:#}"), "Codex restart handoff failed");
            journal.runtime(
                "restart_failed",
                json!({ "provider": "codex", "error": format!("{error:#}") }),
            );
        }
    }
}
