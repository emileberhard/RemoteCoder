use std::path::PathBuf;

use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

use crate::storage::private_state;

pub(crate) struct ShutdownReceipt {
    path: PathBuf,
    instance_id: String,
}

impl ShutdownReceipt {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            instance_id: crate::ids::new_session_uuid(),
        }
    }

    pub(crate) async fn begin(&self) -> Result<()> {
        self.write("running", None, None).await
    }

    pub(crate) async fn finish(&self, codex: &Result<()>, claude: &Result<()>) -> Result<()> {
        let error = |result: &Result<()>| {
            result
                .as_ref()
                .err()
                .map(|error| format!("{error:#}").chars().take(2048).collect::<String>())
        };
        self.write(
            if codex.is_ok() && claude.is_ok() {
                "captured"
            } else {
                "failed"
            },
            error(codex),
            error(claude),
        )
        .await
    }

    async fn write(
        &self,
        status: &'static str,
        codex_error: Option<String>,
        claude_error: Option<String>,
    ) -> Result<()> {
        let path = self.path.clone();
        let instance_id = self.instance_id.clone();
        tokio::task::spawn_blocking(move || {
            private_state::transaction(
                &path,
                "shutdown receipt has no state directory",
                |path| {
                    private_state::read_bounded(path, 8192)
                        .map_err(|error| anyhow::anyhow!("shutdown receipt is unreadable: {error:?}"))?
                        .map(|bytes| serde_json::from_slice::<Value>(&bytes))
                        .transpose().map_err(Into::into)
                },
                |previous| {
                    if status != "running" {
                        ensure!(previous.as_ref().is_some_and(|value| value["instanceId"] == instance_id && value["status"] == "running"), "shutdown receipt belongs to a different gateway instance");
                    }
                    *previous = Some(json!({"schemaVersion":1,"instanceId":instance_id,"pid":std::process::id(),"status":status,"codexError":codex_error,"claudeError":claude_error}));
                    Ok(((), true))
                },
                private_state::write_json,
            )
        }).await.context("shutdown receipt worker failed")?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_the_running_instance_can_publish_a_successful_capture() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway-shutdown.json");
        let first = ShutdownReceipt::new(path.clone());
        first.begin().await.unwrap();
        let next = ShutdownReceipt::new(path.clone());
        next.begin().await.unwrap();
        assert!(first.finish(&Ok(()), &Ok(())).await.is_err());
        next.finish(&Err(anyhow::anyhow!("capture refused")), &Ok(()))
            .await
            .unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["status"], "failed");
        assert_eq!(value["codexError"], "capture refused");
        let final_instance = ShutdownReceipt::new(path.clone());
        final_instance.begin().await.unwrap();
        final_instance.finish(&Ok(()), &Ok(())).await.unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["status"], "captured");
        assert!(value["codexError"].is_null());
        assert!(value["claudeError"].is_null());
    }
}
