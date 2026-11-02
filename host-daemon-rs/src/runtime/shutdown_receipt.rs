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

    pub(crate) async fn begin(&self) {
        if let Err(error) = self.write("running", None, None).await {
            tracing::warn!(%error, "gateway startup receipt could not be persisted");
        }
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
                    private_state::read_bounded(path, 16384)
                        .map_err(|error| anyhow::anyhow!("shutdown receipt is unreadable: {error:?}"))?
                        .map(|bytes| serde_json::from_slice::<Value>(&bytes))
                        .transpose().map_err(Into::into)
                },
                |previous| {
                    if status != "running" {
                        ensure!(previous.as_ref().is_some_and(|value| value["instanceId"] == instance_id && value["status"] == "running"), "shutdown receipt belongs to a different gateway instance");
                    }
                    let predecessor = previous.as_ref().and_then(|record| {
                        if status == "running" && record["status"] != "running" {
                            let mut record = record.clone();
                            record.as_object_mut()?.remove("previous");
                            Some(record)
                        } else {
                            record.get("previous").cloned()
                        }
                    });
                    let mut record = json!({"schemaVersion":1,"instanceId":instance_id,"pid":std::process::id(),"status":status,"codexError":codex_error,"claudeError":claude_error});
                    if let Some(predecessor) = predecessor {
                        record["previous"] = predecessor;
                    }
                    *previous = Some(record);
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
        first.begin().await;
        let next = ShutdownReceipt::new(path.clone());
        next.begin().await;
        assert!(first.finish(&Ok(()), &Ok(())).await.is_err());
        next.finish(&Err(anyhow::anyhow!("capture refused")), &Ok(()))
            .await
            .unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["status"], "failed");
        assert_eq!(value["codexError"], "capture refused");
        let final_instance = ShutdownReceipt::new(path.clone());
        final_instance.begin().await;
        final_instance.finish(&Ok(()), &Ok(())).await.unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["status"], "captured");
        assert!(value["codexError"].is_null());
        assert!(value["claudeError"].is_null());
        assert_eq!(value["previous"]["status"], "failed");
        assert_eq!(value["previous"]["codexError"], "capture refused");
        assert!(value["previous"].get("previous").is_none());
    }

    #[tokio::test]
    async fn malformed_evidence_is_preserved_without_failing_startup() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway-shutdown.json");
        for bytes in [b"{unfinished".to_vec(), vec![b'x'; 16385]] {
            std::fs::write(&path, &bytes).unwrap();
            let receipt = ShutdownReceipt::new(path.clone());
            receipt.begin().await;
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert!(receipt.finish(&Ok(()), &Ok(())).await.is_err());
        }
    }
}
