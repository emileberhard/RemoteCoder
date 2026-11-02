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
            result.as_ref().err().map(|error| {
                let mut text = format!("{error:#}");
                let mut end = text.len().min(512);
                while !text.is_char_boundary(end) {
                    end -= 1;
                }
                text.truncate(end);
                text
            })
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
                    let loaded = private_state::read_bounded(path, 16384)
                        .map_err(|error| anyhow::anyhow!("shutdown receipt is unreadable: {error:?}"))
                        .and_then(|bytes| bytes.map(|bytes| serde_json::from_slice::<Value>(&bytes)).transpose().map_err(Into::into))
                        .and_then(|record| {
                            if let Some(record) = &record {
                                ensure!(record["schemaVersion"] == 1
                                    && record["instanceId"].as_str().is_some_and(|id| !id.is_empty())
                                    && record["pid"].as_u64().is_some_and(|pid| pid > 0)
                                    && matches!(record["status"].as_str(), Some("running" | "captured" | "failed")),
                                    "shutdown receipt has an invalid shape");
                            }
                            Ok(record)
                        });
                    match loaded {
                        Ok(record) => Ok(record),
                        Err(error) if status == "running" => {
                            let quarantine = path.with_extension("invalid.json");
                            std::fs::rename(path, &quarantine).context("malformed shutdown receipt could not be retained")?;
                            tracing::warn!(%error, path=%quarantine.display(), "malformed shutdown receipt retained aside");
                            Ok(None)
                        }
                        Err(error) => Err(error),
                    }
                },
                |previous| {
                    if status != "running" {
                        ensure!(previous.as_ref().is_some_and(|value| value["instanceId"] == instance_id && value["status"] == "running"), "shutdown receipt belongs to a different gateway instance");
                    }
                    let predecessor = previous.as_ref().and_then(|record| {
                        if status == "running" {
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
    async fn multibyte_and_escaped_errors_keep_two_instances_within_the_read_bound() {
        for message in ["界".repeat(2048), "\\\n\0".repeat(2048)] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("gateway-shutdown.json");
            for _ in 0..2 {
                let receipt = ShutdownReceipt::new(path.clone());
                receipt.begin().await;
                receipt
                    .finish(
                        &Err(anyhow::anyhow!(message.clone())),
                        &Err(anyhow::anyhow!(message.clone())),
                    )
                    .await
                    .unwrap();
            }
            let bytes = std::fs::read(&path).unwrap();
            assert!(bytes.len() <= 16384);
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            for record in [&value, &value["previous"]] {
                for field in ["codexError", "claudeError"] {
                    let saved = record[field].as_str().unwrap();
                    assert!(saved.len() <= 512 && message.starts_with(saved));
                }
            }
            ShutdownReceipt::new(path.clone()).begin().await;
            assert!(!path.with_extension("invalid.json").exists());
        }
    }

    #[tokio::test]
    async fn a_crashed_predecessor_is_retained_as_previous() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway-shutdown.json");
        let crashed = ShutdownReceipt::new(path.clone());
        crashed.begin().await;
        let next = ShutdownReceipt::new(path.clone());
        next.begin().await;
        next.finish(&Ok(()), &Ok(())).await.unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["previous"]["instanceId"], crashed.instance_id);
        assert_eq!(value["previous"]["status"], "running");
    }

    #[tokio::test]
    async fn malformed_evidence_is_retained_aside_and_new_capture_can_finish() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway-shutdown.json");
        for bytes in [b"{unfinished".to_vec(), b"[]".to_vec(), vec![b'x'; 16385]] {
            std::fs::write(&path, &bytes).unwrap();
            let receipt = ShutdownReceipt::new(path.clone());
            receipt.begin().await;
            assert_eq!(
                std::fs::read(path.with_extension("invalid.json")).unwrap(),
                bytes
            );
            receipt.finish(&Ok(()), &Ok(())).await.unwrap();
        }
    }
}
