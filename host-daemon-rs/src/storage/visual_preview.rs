use std::process::Stdio;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio::time::{Instant, timeout_at};

const HELPER: &str = "rc-visual-preview";
const TIMEOUT: Duration = Duration::from_secs(15);
const MAX_JPEG_BYTES: usize = 4 * 1024 * 1024;
static RENDERS: Semaphore = Semaphore::const_new(2);

pub(crate) struct Preview {
    pub(crate) summary: String,
    pub(crate) jpeg_base64: String,
    pub(crate) audit: Value,
}

#[derive(Debug)]
pub(crate) struct PreviewError {
    category: &'static str,
    message: String,
}

impl PreviewError {
    fn new(category: &'static str, message: impl Into<String>) -> Self {
        Self {
            category,
            message: message.into(),
        }
    }

    pub(crate) fn audit(&self) -> Value {
        json!({"failure": self.category})
    }
}

impl std::fmt::Display for PreviewError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Report {
    image: String,
    width: u32,
    heights: [u32; 2],
    captured_height: u32,
    content_width: u32,
    visible: bool,
    loaded: bool,
    problems: Vec<Problem>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Problem {
    kind: String,
    message: String,
    location: Option<String>,
}

pub(crate) async fn render(hash: &str, bytes: &[u8]) -> Result<Preview, PreviewError> {
    let queued = Instant::now();
    let _permit = timeout_at(queued + TIMEOUT, RENDERS.acquire())
        .await
        .map_err(|_| PreviewError::new("busy", "other previews kept this Mac busy"))?
        .map_err(|_| PreviewError::new("busy", "previews are shutting down"))?;
    let started = Instant::now();
    let deadline = started + TIMEOUT;
    let helper = std::env::current_exe()
        .map_err(|error| PreviewError::new("helper_missing", error.to_string()))?
        .with_file_name(HELPER);
    let mut child = Command::new(helper)
        .arg(hash)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| match error.kind() {
            std::io::ErrorKind::NotFound => {
                PreviewError::new("helper_missing", "this gateway build has no preview helper")
            }
            _ => PreviewError::new("spawn", error.to_string()),
        })?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| PreviewError::new("spawn", "the helper has no input"))?;
    let output = timeout_at(deadline, async {
        stdin.write_all(bytes).await?;
        drop(stdin);
        child.wait_with_output().await
    })
    .await
    .map_err(|_| PreviewError::new("timeout", "rendering took longer than 15 seconds"))?
    .map_err(|error| PreviewError::new("helper", error.to_string()))?;
    if !output.status.success() {
        let reason = String::from_utf8_lossy(&output.stderr);
        let reason = reason.trim().lines().last().unwrap_or("the helper failed");
        return Err(PreviewError::new(
            "render",
            reason.chars().take(300).collect::<String>(),
        ));
    }
    let report: Report = serde_json::from_slice(&output.stdout)
        .map_err(|error| PreviewError::new("report", error.to_string()))?;
    let jpeg = STANDARD
        .decode(&report.image)
        .map_err(|error| PreviewError::new("report", error.to_string()))?;
    if jpeg.len() > MAX_JPEG_BYTES || !jpeg.starts_with(&[0xFF, 0xD8]) {
        return Err(PreviewError::new("report", "the helper returned no JPEG"));
    }
    let audit = json!({
        "waitMs": started.duration_since(queued).as_millis() as u64,
        "ms": started.elapsed().as_millis() as u64,
        "heights": report.heights,
        "contentWidth": report.content_width,
        "visible": report.visible,
        "loaded": report.loaded,
        "problems": report.problems.len(),
        "jpegBytes": jpeg.len(),
    });
    Ok(Preview {
        summary: summary(&report),
        jpeg_base64: report.image,
        audit,
    })
}

fn summary(report: &Report) -> String {
    let [light, dark] = report.heights;
    let tallest = light.max(dark);
    let heights = if light == dark {
        format!("{light}pt tall")
    } else {
        format!("{light}pt and {dark}pt tall")
    };
    let mut lines = vec![format!(
        "Preview of the visual in light | dark at {}pt wide, {heights}.",
        report.width
    )];
    if report.captured_height < tallest {
        lines.push(format!(
            "The render shows the top {}pt.",
            report.captured_height
        ));
    }
    if report.content_width > report.width {
        lines.push(format!(
            "Content is {}pt wide, so a {}pt phone clips it.",
            report.content_width, report.width
        ));
    }
    if !report.loaded {
        lines.push("Some resources were still loading after 4 seconds.".into());
    }
    if !report.visible {
        lines.push("The page was hidden on this Mac, so animation and timers did not run.".into());
    }
    if report.problems.is_empty() {
        lines.push("No script errors or failed loads.".into());
    } else {
        lines.push("Problems:".into());
        lines.extend(
            report
                .problems
                .iter()
                .map(|problem| match &problem.location {
                    Some(location) => {
                        format!("- {} at {location}: {}", problem.kind, problem.message)
                    }
                    None => format!("- {}: {}", problem.kind, problem.message),
                }),
        );
    }
    lines.push("Check it and republish if anything looks wrong.".into());
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(problems: Vec<Problem>) -> Report {
        Report {
            image: String::new(),
            width: 360,
            heights: [4000, 4000],
            captured_height: 3136,
            content_width: 500,
            visible: false,
            loaded: false,
            problems,
        }
    }

    #[test]
    fn summary_names_every_finding_the_render_made() {
        let summary = summary(&report(vec![
            Problem {
                kind: "error".into(),
                message: "ReferenceError: Can't find variable: chart".into(),
                location: Some("line 13:15".into()),
            },
            Problem {
                kind: "resource".into(),
                message: "img https://example.com/a.png".into(),
                location: None,
            },
        ]));
        assert_eq!(
            summary,
            "Preview of the visual in light | dark at 360pt wide, 4000pt tall.\n\
             The render shows the top 3136pt.\n\
             Content is 500pt wide, so a 360pt phone clips it.\n\
             Some resources were still loading after 4 seconds.\n\
             The page was hidden on this Mac, so animation and timers did not run.\n\
             Problems:\n\
             - error at line 13:15: ReferenceError: Can't find variable: chart\n\
             - resource: img https://example.com/a.png\n\
             Check it and republish if anything looks wrong."
        );
    }
}
