use std::fmt;
use std::io;

use tokio::io::{AsyncBufRead, AsyncBufReadExt};

pub(crate) const MAX_PROVIDER_ID_BYTES: usize = 4_096;
pub(crate) const MAX_PROVIDER_ITEM_ID_BYTES: usize = MAX_PROVIDER_ID_BYTES + 32;

#[derive(Debug, Clone, Copy)]
pub(crate) struct CapacityExceeded {
    pub(crate) resource: &'static str,
    pub(crate) limit: usize,
}

impl CapacityExceeded {
    pub(crate) fn to_value(self) -> serde_json::Value {
        serde_json::json!({"kind":"capacity", "retryable":false,
            "resource":self.resource, "limit":self.limit})
    }
}

impl fmt::Display for CapacityExceeded {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "Claude {} capacity exceeded (limit {})",
            self.resource, self.limit
        )
    }
}

impl std::error::Error for CapacityExceeded {}

impl From<CapacityExceeded> for crate::rpc::error::RpcError {
    fn from(capacity: CapacityExceeded) -> Self {
        Self::new(crate::rpc::error::RpcCode::Capacity, capacity.to_string())
            .with_data(crate::rpc::error::RpcData::Raw(capacity.to_value()))
    }
}

pub(super) fn validate_id(
    id: &str,
    resource: &'static str,
    limit: usize,
) -> Result<(), CapacityExceeded> {
    if id.len() > limit {
        Err(CapacityExceeded { resource, limit })
    } else {
        Ok(())
    }
}

pub(super) async fn read_stream_line(
    reader: &mut (impl AsyncBufRead + Unpin),
    line: &mut Vec<u8>,
    limit: usize,
    resource: &'static str,
) -> io::Result<bool> {
    line.clear();
    loop {
        let buffered = reader.fill_buf().await?;
        if buffered.is_empty() {
            return Ok(!line.is_empty());
        }
        let newline = buffered.iter().position(|byte| *byte == b'\n');
        let length = newline.map_or(buffered.len(), |index| index + 1);
        if length > limit.saturating_sub(line.len()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                CapacityExceeded { resource, limit },
            ));
        }
        line.extend_from_slice(&buffered[..length]);
        reader.consume(length);
        if newline.is_some() {
            return Ok(true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncWriteExt, BufReader};

    #[tokio::test]
    async fn stream_record_capacity_rejects_unterminated_bytes_without_waiting_for_eof() {
        let (mut writer, reader) = tokio::io::duplex(32);
        writer.write_all(b"ok\n123456789").await.unwrap();
        let mut reader = BufReader::with_capacity(3, reader);
        let mut line = Vec::new();
        assert!(
            read_stream_line(&mut reader, &mut line, 8, "test record")
                .await
                .unwrap()
        );
        assert_eq!(line, b"ok\n");
        let error = read_stream_line(&mut reader, &mut line, 8, "test record")
            .await
            .unwrap_err();
        let capacity = error
            .get_ref()
            .unwrap()
            .downcast_ref::<CapacityExceeded>()
            .unwrap();
        assert_eq!(capacity.resource, "test record");
        assert_eq!(capacity.limit, 8);
        assert!(line.len() <= 8);
    }
}
