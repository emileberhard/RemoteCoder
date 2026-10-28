use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use tokio::io::AsyncReadExt;

use super::model::{GitSnapshot, JobResult, MAX_RESULT_BYTES};

pub(super) fn bounded_result(text: String, truncated: bool) -> Result<JobResult> {
    let mut result = JobResult { text, truncated };
    if serde_json::to_vec(&result)?.len() <= MAX_RESULT_BYTES {
        return Ok(result);
    }
    result.truncated = true;
    let original = std::mem::take(&mut result.text);
    let mut low = 0;
    let mut high = original.len();
    while low < high {
        let middle = low + (high - low).div_ceil(2);
        let boundary = original.floor_char_boundary(middle);
        result.text = original[..boundary].to_owned();
        if serde_json::to_vec(&result)?.len() <= MAX_RESULT_BYTES {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    result.text = original[..original.floor_char_boundary(low)].to_owned();
    Ok(result)
}

async fn git(cwd: &Path, args: &[&str]) -> Result<(std::process::ExitStatus, String)> {
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut child = tokio::process::Command::new("git")
            .arg("-C")
            .arg(cwd)
            .args(args)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let mut bytes = Vec::new();
        child
            .stdout
            .take()
            .context("Git stdout is missing")?
            .take(65537)
            .read_to_end(&mut bytes)
            .await?;
        ensure!(
            bytes.len() <= 65536,
            "Git evidence exceeded its output budget"
        );
        let status = child.wait().await?;
        Ok((status, String::from_utf8(bytes)?))
    })
    .await
    .context("Git evidence did not finish within five seconds")?
}

pub(super) async fn git_snapshot(cwd: &Path) -> GitSnapshot {
    let result = async {
        let (head, branch, status) = tokio::try_join!(
            git(cwd, &["rev-parse", "--verify", "HEAD"]),
            git(cwd, &["symbolic-ref", "--quiet", "--short", "HEAD"]),
            git(
                cwd,
                &["status", "--porcelain=v1", "--untracked-files=normal"]
            ),
        )?;
        ensure!(
            head.0.success() && status.0.success(),
            "Git repository evidence is unavailable"
        );
        ensure!(
            branch.0.success() || branch.0.code() == Some(1),
            "Git branch evidence is unavailable"
        );
        Ok::<_, anyhow::Error>(GitSnapshot::Known {
            head: head.1.trim().to_owned(),
            branch: branch.0.success().then(|| branch.1.trim().to_owned()),
            dirty: !status.1.is_empty(),
        })
    }
    .await;
    result.unwrap_or_else(|error| GitSnapshot::Unknown {
        reason: format!("{error:#}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_budget_counts_json_escaping_and_preserves_utf8() {
        let text = "\u{0}🦀".repeat(100_000);
        let result = bounded_result(text.clone(), false).unwrap();
        assert!(result.truncated);
        assert!(text.starts_with(&result.text));
        assert!(serde_json::to_vec(&result).unwrap().len() <= MAX_RESULT_BYTES);
        assert!(result.text.len() > 100_000);
    }
}
