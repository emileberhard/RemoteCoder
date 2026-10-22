use std::collections::HashSet;
use std::io::BufReader;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::providers::claude::records::{LineKind, read_bounded_line};

const MAX_RECORD_BYTES: u64 = 16 << 20;

pub(super) fn recorded_ids<'a>(path: &Path, ids: &[&'a str]) -> Result<HashSet<&'a str>> {
    let file =
        std::fs::File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let mut reader = BufReader::new(file);
    let mut found = HashSet::new();
    let mut line = Vec::new();
    while found.len() < ids.len() {
        line.clear();
        let (_, kind) = read_bounded_line(&mut reader, &mut line, MAX_RECORD_BYTES)
            .with_context(|| format!("failed to read {}", path.display()))?;
        match kind {
            LineKind::Complete => {}
            LineKind::Partial => break,
            LineKind::Oversized => bail!(
                "a record in {} is larger than {MAX_RECORD_BYTES} bytes",
                path.display()
            ),
        }
        if line.trim_ascii().is_empty() {
            continue;
        }
        let record: Value = serde_json::from_slice(&line)
            .with_context(|| format!("failed to parse {}", path.display()))?;
        let recorded_id = match record.get("type").and_then(Value::as_str) {
            Some("user") => record.get("uuid"),
            Some("attachment")
                if record.pointer("/attachment/type").and_then(Value::as_str)
                    == Some("queued_command") =>
            {
                record.pointer("/attachment/source_uuid")
            }
            _ => None,
        };
        if let Some(recorded_id) = recorded_id.and_then(Value::as_str)
            && let Some(id) = ids.iter().find(|id| **id == recorded_id)
        {
            found.insert(*id);
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transcript(contents: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().expect("transcript dir");
        let path = dir.path().join("session.jsonl");
        std::fs::write(&path, contents).expect("transcript");
        (dir, path)
    }

    #[test]
    fn recorded_delivery_requires_an_exact_user_record_or_queued_command_source() {
        let (_dir, path) = transcript(concat!(
            "{\"type\":\"user\",\"uuid\":\"other\",\"message\":\"delivery-1\"}\n",
            "{\"type\":\"user\",\"uuid\":\"delivery-1-extra\"}\n",
            "{\"type\":\"assistant\",\"uuid\":\"delivery-2\"}\n",
            "{\"type\":\"user\",\"uuid\":\"delivery-3\"}\n",
            "{\"type\":\"attachment\",\"uuid\":\"att-5\",\"attachment\":{\"type\":\"queued_command\",\"prompt\":\"later\",\"source_uuid\":\"delivery-5\",\"commandMode\":\"prompt\",\"isMeta\":true}}\n",
            "{\"type\":\"attachment\",\"uuid\":\"att-6\",\"attachment\":{\"type\":\"file\",\"source_uuid\":\"delivery-6\"}}\n",
            "{\"type\":\"user\",\"uuid\":\"delivery-4",
        ));
        let ids = [
            "delivery-1",
            "delivery-2",
            "delivery-3",
            "delivery-4",
            "delivery-5",
            "delivery-6",
        ];

        assert_eq!(
            recorded_ids(&path, &ids).expect("a torn final append is not a delivery"),
            HashSet::from(["delivery-3", "delivery-5"]),
        );
    }

    #[test]
    fn a_final_record_without_its_newline_is_not_yet_a_delivery() {
        let (_dir, path) = transcript(concat!(
            "{\"type\":\"user\",\"uuid\":\"delivery-1\"}\n",
            "{\"type\":\"user\",\"uuid\":\"delivery-2\"}",
        ));

        assert_eq!(
            recorded_ids(&path, &["delivery-1", "delivery-2"]).unwrap(),
            HashSet::from(["delivery-1"]),
        );
    }

    #[test]
    fn a_corrupt_complete_record_or_an_oversized_one_is_an_error_not_absence() {
        let (_dir, path) = transcript("{broken\n{\"type\":\"user\",\"uuid\":\"delivery-3\"}\n");
        assert!(recorded_ids(&path, &["delivery-3"]).is_err());

        let (_dir, path) = transcript(&format!("{}\n", "x".repeat(MAX_RECORD_BYTES as usize + 1)));
        assert!(recorded_ids(&path, &["delivery-3"]).is_err());
    }
}
