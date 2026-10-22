use crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES;
use anyhow::{Context, Result};
use serde_json::Value;
use std::io::{self, Write};

pub(crate) enum EncodedJson {
    Text(String),
    Capacity { bytes: usize },
}

enum JsonOutput {
    Retained(Vec<u8>),
    Counted,
    Within(usize),
}

struct CappedWriter {
    output: JsonOutput,
    bytes: usize,
}

impl Default for CappedWriter {
    fn default() -> Self {
        Self {
            output: JsonOutput::Retained(Vec::with_capacity(128)),
            bytes: 0,
        }
    }
}

impl Write for CappedWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.bytes = self
            .bytes
            .checked_add(bytes.len())
            .ok_or_else(|| io::Error::other("encoded frame size overflow"))?;
        if let JsonOutput::Within(limit) = self.output
            && self.bytes > limit
        {
            return Err(io::Error::other("JSON byte budget exceeded"));
        }
        if let JsonOutput::Retained(output) = &mut self.output
            && self.bytes <= MAX_WEBSOCKET_BYTES
        {
            if self.bytes > output.capacity() {
                let capacity = self.bytes.next_power_of_two().min(MAX_WEBSOCKET_BYTES);
                output
                    .try_reserve_exact(capacity - output.len())
                    .map_err(io::Error::other)?;
            }
            output.extend_from_slice(bytes);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(crate) fn encode(message: &Value) -> Result<EncodedJson> {
    let mut writer = CappedWriter::default();
    serde_json::to_writer(&mut writer, message)?;
    if writer.bytes > MAX_WEBSOCKET_BYTES {
        Ok(EncodedJson::Capacity {
            bytes: writer.bytes,
        })
    } else {
        let JsonOutput::Retained(output) = writer.output else {
            anyhow::bail!("retaining encoder has no output buffer");
        };
        Ok(EncodedJson::Text(
            String::from_utf8(output).context("JSON encoder produced invalid UTF-8")?,
        ))
    }
}

pub(crate) fn encoded_len<T: serde::Serialize + ?Sized>(value: &T) -> Result<usize> {
    let mut writer = CappedWriter {
        output: JsonOutput::Counted,
        bytes: 0,
    };
    serde_json::to_writer(&mut writer, value)?;
    Ok(writer.bytes)
}

pub(crate) fn encoded_len_at_most<T: serde::Serialize + ?Sized>(
    value: &T,
    limit: usize,
) -> Result<Option<usize>> {
    let mut writer = CappedWriter {
        output: JsonOutput::Within(limit),
        bytes: 0,
    };
    match serde_json::to_writer(&mut writer, value) {
        Ok(()) => Ok(Some(writer.bytes)),
        Err(_) if writer.bytes > limit => Ok(None),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_capacity_encoder_bounds_escaped_output_and_counts_without_retaining_overflow() {
        let message =
            serde_json::json!({"id":"escaped","result":{"text":"\0".repeat(6 * 1024 * 1024)}});
        let mut writer = CappedWriter::default();
        serde_json::to_writer(&mut writer, &message).unwrap();
        assert!(writer.bytes > MAX_WEBSOCKET_BYTES);
        assert_eq!(
            writer.bytes,
            36 * 1024 * 1024 + r#"{"id":"escaped","result":{"text":""}}"#.len()
        );
        let JsonOutput::Retained(output) = &writer.output else {
            panic!("retained buffer missing");
        };
        assert!(output.len() <= MAX_WEBSOCKET_BYTES);
        assert!(output.capacity() <= MAX_WEBSOCKET_BYTES);
        writer.write_all(b"later bytes").unwrap();
        let JsonOutput::Retained(output) = &writer.output else {
            panic!("retained buffer missing");
        };
        assert!(output.capacity() <= MAX_WEBSOCKET_BYTES);
        let EncodedJson::Capacity { bytes } = encode(&message).unwrap() else {
            panic!("escaped output must be rejected")
        };
        assert_eq!(bytes, writer.bytes - b"later bytes".len());
    }

    #[test]
    fn rpc_capacity_counting_mode_matches_normal_json_bytes_without_an_output_buffer() {
        for value in [
            serde_json::json!({"input":{"command":"echo \"Åsa 🚀\"\n"},"usage":{"input_tokens":123},"slash":"\\","control":"\u{0000}"}),
            serde_json::json!({"type":"mcpToolCall","arguments":{},"result":{"content":[{"type":"text","text":"answer"}]}}),
            serde_json::json!({"data":[{"itemId":"i1","questions":[{"header":"Choose","options":["a","b"]}]}],"float":1e15}),
            serde_json::json!([]),
        ] {
            let expected = serde_json::to_vec(&value).unwrap().len();
            let mut writer = CappedWriter {
                output: JsonOutput::Counted,
                bytes: 0,
            };
            serde_json::to_writer(&mut writer, &value).unwrap();
            assert!(matches!(writer.output, JsonOutput::Counted));
            assert_eq!(writer.bytes, expected);
            assert_eq!(encoded_len(&value).unwrap(), expected);
        }
        let escaped = serde_json::json!("\0".repeat(6 * 1024 * 1024));
        let mut writer = CappedWriter {
            output: JsonOutput::Counted,
            bytes: 0,
        };
        serde_json::to_writer(&mut writer, &escaped).unwrap();
        assert!(matches!(writer.output, JsonOutput::Counted));
        assert_eq!(writer.bytes, 36 * 1024 * 1024 + 2);
    }

    #[test]
    fn review_budget_counter_stops_without_retaining_or_claiming_an_exact_size() {
        let value = serde_json::json!({"text":"\0".repeat(1024 * 1024)});
        let mut writer = CappedWriter {
            output: JsonOutput::Within(64),
            bytes: 0,
        };
        assert!(
            serde_json::to_writer(&mut writer, &value)
                .unwrap_err()
                .is_io()
        );
        assert!(matches!(writer.output, JsonOutput::Within(64)));
        assert!(writer.bytes > 64 && writer.bytes < 128);
        assert_eq!(encoded_len_at_most(&value, 64).unwrap(), None);
        let value = serde_json::json!({"role":"user","text":"Åsa 🚀\n"});
        let bytes = serde_json::to_vec(&value).unwrap().len();
        assert_eq!(encoded_len_at_most(&value, bytes).unwrap(), Some(bytes));
        assert_eq!(encoded_len_at_most(&value, bytes - 1).unwrap(), None);
    }
}
