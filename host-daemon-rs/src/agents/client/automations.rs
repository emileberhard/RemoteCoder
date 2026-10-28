use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

use super::{ListArgs, RpcFailure};
use crate::config::HostPaths;

async fn bounded(stream: impl AsyncRead + Unpin, limit: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    stream
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .await?;
    ensure!(
        bytes.len() <= limit,
        "Automation CLI response exceeds its byte budget"
    );
    Ok(bytes)
}

async fn call(arguments: &[&str], input: Option<&str>) -> Result<Value> {
    let executable = HostPaths::from_env()?.home().join("scripts/automations");
    let mut child = Command::new(executable)
        .args(arguments)
        .arg("--json")
        .kill_on_drop(true)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Cannot start the automation service's CLI")?;
    let mut stdin = child.stdin.take().context("Automation CLI has no stdin")?;
    let stdout = child
        .stdout
        .take()
        .context("Automation CLI has no stdout")?;
    let stderr = child
        .stderr
        .take()
        .context("Automation CLI has no stderr")?;
    let (stdout, stderr, status, ()) = tokio::time::timeout(Duration::from_secs(100), async {
        tokio::try_join!(
            bounded(stdout, 8 * 1024 * 1024),
            bounded(stderr, 16 * 1024),
            async { child.wait().await.map_err(anyhow::Error::from) },
            async {
                if let Some(input) = input {
                    stdin.write_all(input.as_bytes()).await?;
                }
                stdin.shutdown().await?;
                Ok::<_, anyhow::Error>(())
            },
        )
    })
    .await
    .context(
        "Automation CLI acknowledgement timed out; inspect the same request ID before retrying",
    )??;
    if !stderr.is_empty() {
        eprint!("{}", String::from_utf8_lossy(&stderr));
    }
    let payload: Value =
        serde_json::from_slice(&stdout).context("Automation CLI returned invalid JSON")?;
    if payload["ok"] != true {
        return Err(RpcFailure(payload["error"].clone()).into());
    }
    ensure!(
        status.success(),
        "Automation CLI failed after returning a response"
    );
    Ok(payload)
}

pub(super) async fn listing(arguments: &ListArgs) -> Result<Value> {
    let limit = arguments.last.to_string();
    let payload = call(&["list", "--prefix", "run/", "--limit", &limit], None).await?;
    let rows = payload["data"]["items"]
        .as_array()
        .context("Automation service returned no run list")?;
    let rows = rows
        .iter()
        .filter(|row| {
            row["provider"].is_string()
                && arguments
                    .provider
                    .as_deref()
                    .is_none_or(|provider| row["provider"] == provider)
                && (!arguments.active
                    || matches!(
                        row["state"].as_str(),
                        Some("queued" | "running" | "uncertain")
                    ))
        })
        .map(|row| {
            let mut row = row.clone();
            row["run_id"] = json!(format!(
                "automation:{}",
                row["id"].as_str().unwrap_or_default()
            ));
            row
        })
        .collect::<Vec<_>>();
    Ok(json!({"source":"automations","agents":rows,"health":payload["health"]}))
}

pub(super) async fn read(target: &str) -> Result<Value> {
    let id = format!("run/{}", target.trim_start_matches("automation:"));
    let payload = call(&["show", &id], None).await?;
    Ok(json!({"source":"automations","agents":[payload["data"]],"health":payload["health"]}))
}

pub(super) async fn steer(target: &str, text: &str, delivery_id: &str) -> Result<Value> {
    let run = target.trim_start_matches("automation:");
    call(
        &[
            "run",
            "--steer",
            run,
            "--message",
            "-",
            "--request-id",
            delivery_id,
        ],
        Some(text),
    )
    .await
}
