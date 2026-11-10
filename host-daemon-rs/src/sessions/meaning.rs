use super::{conversations::Request, index, query, store::Reader};
use crate::config::ConfigSources;
use anyhow::{Context, Result, ensure};
use nix::{
    sys::signal::{Signal, killpg},
    unistd::Pid,
};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::Semaphore,
};

pub(crate) const ENV_KEY: &str = "RC_CODEX_GATEWAY_CONVERSATION_SEARCH_PROVIDER_FILE";
pub(crate) const DEADLINE: Duration = Duration::from_secs(8);
const OUTPUT_BYTES: u64 = 1 << 20;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    command: PathBuf,
    args: Vec<String>,
}

#[derive(Debug)]
pub(crate) struct Provider {
    command: Command,
    permits: Arc<Semaphore>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Hit {
    session_id: String,
    provider: String,
    summary: String,
    score: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Output {
    conversations: Vec<Hit>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Response {
    schema_version: u32,
    conversations: Vec<Conversation>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Conversation {
    session_key: String,
    host_id: String,
    provider: String,
    thread_id: String,
    title: Option<String>,
    cwd: Option<String>,
    last_at: Option<String>,
    summary: String,
}

impl Provider {
    pub(crate) fn load(sources: &ConfigSources) -> Result<Option<Arc<Self>>> {
        let Some(path) = sources.optional_string(ENV_KEY) else {
            return Ok(None);
        };
        let path = PathBuf::from(path);
        ensure!(path.is_absolute(), "{ENV_KEY} must be an absolute path");
        let bytes = crate::storage::private_state::read_bounded(&path, 64 * 1024)
            .map_err(|error| anyhow::anyhow!("search provider file is unreadable: {error:?}"))?
            .context("search provider file is missing")?;
        let command: Command =
            serde_json::from_slice(&bytes).context("search provider file is invalid")?;
        ensure!(
            command.command.is_absolute(),
            "search provider command must be absolute"
        );
        ensure!(
            command.args.len() <= 64,
            "search provider accepts at most 64 command arguments"
        );
        Ok(Some(Arc::new(Self {
            command,
            permits: Arc::new(Semaphore::new(2)),
        })))
    }

    pub(crate) async fn search(&self, request: &Request) -> Result<Vec<Hit>> {
        request.validate()?;
        let _permit = self.permits.clone().acquire_owned().await?;
        let mut child = tokio::process::Command::new(&self.command.command)
            .args(&self.command.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .context("search provider could not start")?;
        let _group = Group(
            child
                .id()
                .and_then(|id| i32::try_from(id).ok())
                .map(Pid::from_raw),
        );
        let mut stdin = child
            .stdin
            .take()
            .context("search provider stdin is unavailable")?;
        let mut stdout = child
            .stdout
            .take()
            .context("search provider stdout is unavailable")?
            .take(OUTPUT_BYTES + 1);
        let mut bytes = Vec::new();
        let input = serde_json::to_vec(request)?;
        let write = async {
            stdin.write_all(&input).await?;
            stdin.shutdown().await
        };
        let read = async {
            stdout.read_to_end(&mut bytes).await?;
            ensure!(
                bytes.len() as u64 <= OUTPUT_BYTES,
                "capacity: search provider output exceeds 1 MiB"
            );
            Ok::<_, anyhow::Error>(())
        };
        let ((), (), status) = tokio::try_join!(
            async { write.await.map_err(anyhow::Error::from) },
            read,
            async { child.wait().await.map_err(anyhow::Error::from) }
        )?;
        ensure!(status.success(), "search provider failed");
        let output: Output =
            serde_json::from_slice(&bytes).context("search provider output is invalid")?;
        Ok(output.conversations)
    }
}

struct Group(Option<Pid>);
impl Drop for Group {
    fn drop(&mut self) {
        if let Some(pid) = self.0 {
            let _ = killpg(pid, Signal::SIGKILL);
        }
    }
}

pub(crate) fn resolve(db: &Reader, hits: Vec<Hit>, limit: usize) -> Result<Response> {
    let tx = db.unchecked_transaction()?;
    let mut conversations = Vec::new();
    let mut seen = HashSet::new();
    for hit in hits {
        if !matches!(hit.provider.as_str(), "claude" | "codex") || !hit.score.is_finite() {
            continue;
        }
        let keys: Vec<String> = tx.prepare("SELECT session_key FROM session JOIN source USING(source_id) WHERE session.provider=?1 AND thread_id=?2 AND present=1 LIMIT 2")?.query_map(params![hit.provider,if hit.provider=="claude" { format!("claude_{}",hit.session_id) } else { hit.session_id }], |r|r.get(0))?.collect::<rusqlite::Result<_>>()?;
        if keys.len() != 1 {
            continue;
        }
        let root = index::root(&tx, &keys[0])?;
        if !seen.insert(root.clone()) {
            continue;
        }
        let header = tx.query_row("SELECT s.session_key,s.origin_host,s.provider,s.thread_id,s.cwd,s.title,s.started_at,s.last_at,s.parent_session_key,src.present FROM session s JOIN source src USING(source_id) WHERE s.session_key=?1 AND src.present=1",[root],query::session_header)?;
        conversations.push(Conversation {
            session_key: header.session_key,
            host_id: header.host_id,
            provider: header.provider,
            thread_id: header.thread_id,
            title: header.title,
            cwd: header.cwd,
            last_at: header.last_at,
            summary: hit.summary,
        });
        if conversations.len() == limit {
            break;
        }
    }
    Ok(Response {
        schema_version: 1,
        conversations,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider(args: Vec<String>) -> Provider {
        Provider {
            command: Command {
                command: "/bin/sh".into(),
                args,
            },
            permits: Arc::new(Semaphore::new(2)),
        }
    }

    #[tokio::test]
    async fn meaning_provider_checks_stdout_and_cancel_kills_the_process_group() -> Result<()> {
        let request = Request {
            query: "sidebar stuttered on reveal with more than eight query words".into(),
            limit: 20,
        };
        let good = provider(vec![
            "-c".into(),
            r#"cat >/dev/null; printf '{"conversations":[]}'"#.into(),
        ]);
        assert!(good.search(&request).await?.is_empty());
        let large = provider(vec!["-c".into(), "head -c 1048577 /dev/zero".into()]);
        assert!(
            large
                .search(&request)
                .await
                .err()
                .unwrap()
                .to_string()
                .contains("1 MiB")
        );
        let directory = tempfile::tempdir()?;
        let pid = directory.path().join("pid");
        let slow = Arc::new(provider(vec![
            "-c".into(),
            "echo $$ > \"$1\"; sleep 30".into(),
            "fixture".into(),
            pid.to_string_lossy().into_owned(),
        ]));
        let running = slow.clone();
        let task = tokio::spawn(async move { running.search(&request).await });
        tokio::time::timeout(Duration::from_secs(2), async {
            while !pid.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await?;
        let child: i32 = std::fs::read_to_string(pid)?.trim().parse()?;
        task.abort();
        assert!(matches!(task.await, Err(error) if error.is_cancelled()));
        assert_eq!(slow.permits.available_permits(), 2);
        tokio::time::timeout(Duration::from_secs(2), async {
            while nix::sys::signal::kill(Pid::from_raw(child), None).is_ok() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await?;
        Ok(())
    }
}
