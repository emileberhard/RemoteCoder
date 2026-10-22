use std::fs;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand_core::{OsRng, RngCore};
use serde::Deserialize;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct UuidBytes(pub(crate) [u8; 16]);

impl<'de> Deserialize<'de> for UuidBytes {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        parse_uuid(&value).ok_or_else(|| serde::de::Error::custom("invalid UUID"))
    }
}

pub(crate) fn parse_uuid(value: &str) -> Option<UuidBytes> {
    let bytes = value.as_bytes();
    if bytes.len() != 36 || ![8, 13, 18, 23].into_iter().all(|i| bytes[i] == b'-') {
        return None;
    }
    let mut id = [0; 16];
    let mut offset = 0;
    let mut high = None;
    for &byte in bytes {
        if byte == b'-' {
            continue;
        }
        let digit = (byte as char).to_digit(16)? as u8;
        if let Some(upper) = high.take() {
            id[offset] = (upper << 4) | digit;
            offset += 1;
        } else {
            high = Some(digit);
        }
    }
    (offset == 16).then_some(UuidBytes(id))
}

pub(crate) fn format_uuid(id: UuidBytes) -> String {
    let hex = id.0.map(|byte| format!("{byte:02x}")).concat();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

/// Generates the session id the daemon hands to `claude --session-id`.
///
/// The CLI rejects anything that is not a v4 UUID, so the version and variant
/// bits are set explicitly.
pub(crate) fn new_session_uuid() -> String {
    let mut bytes = [0u8; 16];
    std::io::Read::read_exact(
        &mut fs::File::open("/dev/urandom").expect("/dev/urandom is unavailable"),
        &mut bytes,
    )
    .expect("failed reading /dev/urandom");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format_uuid(UuidBytes(bytes))
}

pub(crate) fn is_session_uuid(value: &str) -> bool {
    parse_uuid(value).is_some()
}

pub(crate) fn random_identifier(byte_count: usize) -> String {
    let mut bytes = vec![0_u8; byte_count];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_ids_keep_the_v4_shape_and_uuid_validation_rejects_bad_separators() {
        let id = new_session_uuid();
        assert!(is_session_uuid(&id));
        assert_eq!(id.as_bytes()[14], b'4');
        assert!(matches!(id.as_bytes()[19], b'8' | b'9' | b'a' | b'b'));
        assert!(!is_session_uuid(&id.replace('-', "_")));
        assert_eq!(format_uuid(parse_uuid(&id).unwrap()), id);
    }
}
