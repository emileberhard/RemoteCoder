use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde_json::Value;

use crate::providers::codex::daemon::CodexAppServer;
use crate::runtime::recovery::{RecoveryPhase, RecoveryStore, RecoveryTaskStatus};

const RECOVERY_INGRESS_TIMEOUT: Duration = Duration::from_secs(600);

pub(crate) async fn finish_before_ingress(
    codex: &CodexAppServer,
    store: &RecoveryStore,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + RECOVERY_INGRESS_TIMEOUT;
    loop {
        if crate::runtime::finish_orphaned_recovery(codex, store).await? {
            return Ok(());
        }
        if store
            .load()?
            .is_some_and(|journal| journal.phase == RecoveryPhase::Completed)
        {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("timed out waiting to lift the restart recovery ingress fence");
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

pub(crate) async fn record_notification_status(
    store: RecoveryStore,
    thread_id: String,
    turn_id: String,
    status: RecoveryTaskStatus,
) -> Result<bool> {
    tokio::task::spawn_blocking(move || {
        let Some(journal) = store.load()? else {
            return Ok(false);
        };
        if !matches!(
            journal.phase,
            RecoveryPhase::Recovering | RecoveryPhase::Recovered | RecoveryPhase::Completed
        ) {
            // Suspension emits an interruption of the captured attempt, not its recovery.
            return Ok(false);
        }
        if !journal
            .tasks
            .iter()
            .any(|task| task.thread_id == thread_id && task.turn_id == turn_id)
        {
            return Ok(false);
        }
        store.update(&journal.generation_id, |journal| {
            let task = journal
                .tasks
                .iter_mut()
                .find(|task| task.thread_id == thread_id && task.turn_id == turn_id)
                .context("recovery task disappeared during update")?;
            task.update_status(status, None);
            Ok(())
        })?;
        Ok::<_, anyhow::Error>(true)
    })
    .await
    .context("restart recovery notification task failed")?
}

pub(crate) fn recovery_status(
    result: &Value,
    generation_id: &str,
    thread_id: &str,
    turn_id: &str,
) -> Result<RecoveryTaskStatus> {
    if result.get("generationId").and_then(Value::as_str) != Some(generation_id)
        || result.pointer("/turn/id").and_then(Value::as_str) != Some(turn_id)
    {
        return Err(anyhow!(
            "Codex returned an invalid recovery acknowledgement for {thread_id}:{turn_id}"
        ));
    }
    match result.pointer("/turn/status").and_then(Value::as_str) {
        Some("inProgress") => Ok(RecoveryTaskStatus::Running),
        Some("completed") => Ok(RecoveryTaskStatus::Completed),
        Some("failed") => Ok(RecoveryTaskStatus::Failed),
        status => Err(anyhow!(
            "Codex returned invalid recovery turn status {status:?} for {thread_id}:{turn_id}"
        )),
    }
}

pub(crate) fn recovery_control_error_is_retryable(error: &anyhow::Error) -> bool {
    let Ok(error) = serde_json::from_str::<Value>(&error.to_string()) else {
        return true;
    };
    !matches!(
        error.get("code").and_then(Value::as_i64),
        Some(-32602..=-32600)
    )
}

pub(crate) fn recovery_control_error_is_unauthorized(error: &anyhow::Error) -> bool {
    let Ok(error) = serde_json::from_str::<Value>(&error.to_string()) else {
        return false;
    };
    error.get("code").and_then(Value::as_i64) == Some(-32600)
        && matches!(
            error.get("message").and_then(Value::as_str),
            Some(
                "restart recovery is not authorized"
                    | "invalid restart recovery capability"
                    | "thread and turn are not authorized for this restart generation"
            )
        )
}

pub(crate) async fn update_recovery_phase(
    store: RecoveryStore,
    generation_id: String,
    phase: RecoveryPhase,
    error: Option<String>,
) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        store.update(&generation_id, |journal| {
            journal.phase = phase;
            journal.error = error;
            Ok(())
        })?;
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("restart recovery phase update task failed")?
}

pub(crate) async fn update_recovery_task(
    store: RecoveryStore,
    generation_id: String,
    thread_id: String,
    turn_id: String,
    status: RecoveryTaskStatus,
    error: Option<String>,
) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        store.update(&generation_id, |journal| {
            let task = journal
                .tasks
                .iter_mut()
                .find(|task| task.thread_id == thread_id && task.turn_id == turn_id)
                .context("recovery task disappeared during update")?;
            task.update_status(status, error);
            Ok(())
        })?;
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("restart recovery task update failed")?
}

pub(crate) async fn record_recovery_task_failure(
    store: RecoveryStore,
    generation_id: String,
    thread_id: String,
    turn_id: String,
    retryable: bool,
    error: String,
) -> Result<RecoveryTaskStatus> {
    tokio::task::spawn_blocking(move || {
        let journal = store.update(&generation_id, |journal| {
            let task = journal
                .tasks
                .iter_mut()
                .find(|task| task.thread_id == thread_id && task.turn_id == turn_id)
                .context("recovery task disappeared during failure update")?;
            task.record_failure(retryable, error);
            Ok(())
        })?;
        journal
            .tasks
            .into_iter()
            .find(|task| task.thread_id == thread_id && task.turn_id == turn_id)
            .map(|task| task.status)
            .context("recovery task disappeared after failure update")
    })
    .await
    .context("restart recovery task failure update failed")?
}
