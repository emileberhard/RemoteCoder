use std::borrow::Cow;
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::SystemTime;

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::value::RawValue;

use crate::providers::claude::wake_hold::WakeHold;
use crate::storage::private_state::{self, Creation};

#[derive(Deserialize)]
struct RecordIdentity<'a> {
    #[serde(rename = "type", borrow)]
    kind: Option<Cow<'a, str>>,
    #[serde(rename = "sessionId", borrow)]
    session_id: Option<&'a RawValue>,
}

enum Title {
    Custom,
    Generated,
}

pub(crate) fn restored_crons(source: &File, length: u64) -> Result<Vec<String>> {
    let mut prefix = source;
    prefix.seek(SeekFrom::Start(0))?;
    Ok(WakeHold::restored_crons(
        prefix.take(length),
        tokio::time::Instant::now(),
        SystemTime::now(),
    )?)
}

pub(crate) fn copy_transcript(
    mut source: File,
    length: u64,
    target: &Path,
    session_uuid: &str,
) -> Result<()> {
    source.seek(SeekFrom::Start(0))?;
    let mut reader = BufReader::new(source);
    let creation = private_state::create_new_with(target, |file| {
        let mut writer = BufWriter::new(file);
        let mut line = Vec::new();
        let mut offset = 0u64;
        let (mut custom_title, mut generated_title) = (None, None);
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line)? == 0 || line.last() != Some(&b'\n') {
                break;
            }
            let start = offset;
            offset += line.len() as u64;
            if start < length {
                ensure!(
                    offset <= length,
                    "The fork boundary splits a Claude session record"
                );
                writer.write_all(&with_session(&line, session_uuid)?)?;
                continue;
            }
            match title(&line) {
                Some(Title::Custom) => {
                    custom_title = Some(with_session(&line, session_uuid)?.into_owned())
                }
                Some(Title::Generated) => {
                    generated_title = Some(with_session(&line, session_uuid)?.into_owned())
                }
                None => {}
            }
        }
        ensure!(
            offset >= length,
            "The Claude session is shorter than its fork boundary"
        );
        for record in [generated_title, custom_title].into_iter().flatten() {
            writer.write_all(&record)?;
        }
        writer.flush()?;
        Ok(())
    })?;
    ensure!(
        creation == Creation::Created,
        "{} already exists",
        target.display()
    );
    Ok(())
}

fn title(line: &[u8]) -> Option<Title> {
    let record = serde_json::from_slice::<RecordIdentity<'_>>(line).ok()?;
    match record.kind.as_deref() {
        Some("custom-title") => Some(Title::Custom),
        Some("ai-title") => Some(Title::Generated),
        _ => None,
    }
}

fn with_session<'a>(line: &'a [u8], session_uuid: &str) -> Result<Cow<'a, [u8]>> {
    let Ok(record) = serde_json::from_slice::<RecordIdentity<'_>>(line) else {
        return Ok(Cow::Borrowed(line));
    };
    let Some(raw) = record.session_id.map(RawValue::get) else {
        return Ok(Cow::Borrowed(line));
    };
    if !raw.starts_with('"') {
        return Ok(Cow::Borrowed(line));
    }
    let start = (raw.as_ptr() as usize)
        .checked_sub(line.as_ptr() as usize)
        .context("Claude session id is outside its record")?;
    let end = start + raw.len();
    ensure!(
        line.get(start..end) == Some(raw.as_bytes()),
        "Claude session id is outside its record"
    );
    let mut rewritten = Vec::with_capacity(line.len());
    rewritten.extend_from_slice(&line[..start]);
    rewritten.extend_from_slice(serde_json::to_string(session_uuid)?.as_bytes());
    rewritten.extend_from_slice(&line[end..]);
    Ok(Cow::Owned(rewritten))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const NEW: &str = "99999999-2222-4333-8444-555555555555";

    fn lines(records: &[Value]) -> String {
        records.iter().map(|record| format!("{record}\n")).collect()
    }

    fn fork(contents: &str, length: u64) -> Result<String> {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.jsonl");
        std::fs::write(&source, contents).unwrap();
        let target = directory.path().join(format!("{NEW}.jsonl"));
        copy_transcript(File::open(&source).unwrap(), length, &target, NEW)?;
        Ok(std::fs::read_to_string(target).unwrap())
    }

    #[test]
    fn the_prefix_keeps_every_byte_except_the_session_identity() {
        let prompt = |session: &str| {
            format!(
                "{{\"type\":\"user\",\"message\":{{\"content\":\"a  b\",\"sessionId\":\"old\"}},\"uuid\":\"u1\",\"sessionId\":\"{session}\",\"session_id\":\"old\"}}\n"
            )
        };
        let boundary = |session: &str| {
            format!(
                "{{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"parentUuid\":null,\"sessionId\":\"{session}\"}}\n"
            )
        };
        let kept = format!("{}{}not json\n", prompt("old"), boundary("old"));
        let dropped = "{\"type\":\"user\",\"uuid\":\"u2\",\"sessionId\":\"old\"}\n";

        let forked = fork(&format!("{kept}{dropped}{{\"partial\""), kept.len() as u64).unwrap();

        assert_eq!(
            forked,
            format!("{}{}not json\n", prompt(NEW), boundary(NEW))
        );
    }

    #[test]
    fn the_latest_titles_after_the_boundary_follow_the_fork() {
        let prefix = lines(&[
            json!({"type":"user","uuid":"u1","sessionId":"old"}),
            json!({"type":"ai-title","aiTitle":"First","sessionId":"old"}),
        ]);
        let suffix = lines(&[
            json!({"type":"user","uuid":"u2","sessionId":"old"}),
            json!({"type":"custom-title","customTitle":"Named","sessionId":"old"}),
            json!({"type":"ai-title","aiTitle":"Later","sessionId":"old"}),
            json!({"type":"custom-title","customTitle":"Renamed","sessionId":"old"}),
        ]);
        let forked = fork(&format!("{prefix}{suffix}"), prefix.len() as u64).unwrap();
        let records: Vec<Value> = forked
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();

        assert_eq!(
            records,
            [
                json!({"type":"user","uuid":"u1","sessionId":NEW}),
                json!({"type":"ai-title","aiTitle":"First","sessionId":NEW}),
                json!({"type":"ai-title","aiTitle":"Later","sessionId":NEW}),
                json!({"type":"custom-title","customTitle":"Renamed","sessionId":NEW}),
            ]
        );
    }

    #[test]
    fn a_boundary_inside_a_record_or_past_the_end_is_refused() {
        let contents = lines(&[json!({"type":"user","uuid":"u1","sessionId":"old"})]);
        assert!(fork(&contents, 5).is_err());
        assert!(fork(&contents, contents.len() as u64 + 1).is_err());
    }
}
