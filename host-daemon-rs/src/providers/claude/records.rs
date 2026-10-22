use std::io::{BufRead, Read};
use std::path::Path;

use anyhow::Result;

use crate::storage::private_state;

pub(crate) const SYNTHETIC_MODEL: &str = "<synthetic>";
pub(crate) const MAX_SESSION_RECORD_BYTES: u64 = 64 << 20;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum LineKind {
    Complete,
    Partial,
    Oversized,
}

pub(crate) fn read_bounded_line(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
    max_bytes: u64,
) -> std::io::Result<(u64, LineKind)> {
    let mut read = reader.by_ref().take(max_bytes).read_until(b'\n', line)? as u64;
    if line.last() == Some(&b'\n') {
        return Ok((read, LineKind::Complete));
    }
    if read < max_bytes {
        return Ok((read, LineKind::Partial));
    }
    line.clear();
    loop {
        let buffered = reader.fill_buf()?;
        if buffered.is_empty() {
            return Ok((read, LineKind::Partial));
        }
        match buffered.iter().position(|byte| *byte == b'\n') {
            Some(end) => {
                reader.consume(end + 1);
                return Ok((read + end as u64 + 1, LineKind::Oversized));
            }
            None => {
                let length = buffered.len();
                reader.consume(length);
                read += length as u64;
            }
        }
    }
}

pub(crate) fn read_record(path: &Path, max_bytes: u64) -> Result<Option<Vec<u8>>> {
    private_state::read_bounded(path, max_bytes).map_err(|error| match error {
        private_state::ReadError::Io(error) => error.into(),
        private_state::ReadError::NotRegular => {
            anyhow::anyhow!("{} is not a regular file", path.display())
        }
        private_state::ReadError::TooLargeBeforeRead
        | private_state::ReadError::TooLargeAfterRead => {
            anyhow::anyhow!("{} is too large", path.display())
        }
    })
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    fn read(contents: &[u8], max: u64) -> Vec<(Vec<u8>, u64, LineKind)> {
        let mut reader = Cursor::new(contents);
        let mut lines = Vec::new();
        loop {
            let mut line = Vec::new();
            let (read, kind) = read_bounded_line(&mut reader, &mut line, max).unwrap();
            if read == 0 {
                return lines;
            }
            let last = kind == LineKind::Partial;
            lines.push((line, read, kind));
            if last {
                return lines;
            }
        }
    }

    #[test]
    fn a_line_over_the_bound_is_skipped_whole_and_the_next_one_is_read() {
        let lines = read(b"ab\nabcdefgh\nc\n", 4);

        assert_eq!(
            lines,
            [
                (b"ab\n".to_vec(), 3, LineKind::Complete),
                (Vec::new(), 9, LineKind::Oversized),
                (b"c\n".to_vec(), 2, LineKind::Complete),
            ]
        );
    }

    #[test]
    fn an_unterminated_final_line_is_partial_however_long() {
        assert_eq!(read(b"ab", 4), [(b"ab".to_vec(), 2, LineKind::Partial)]);
        assert_eq!(read(b"abcdefgh", 4), [(Vec::new(), 8, LineKind::Partial)]);
    }
}
