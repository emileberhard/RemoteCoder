use sha2::{Digest, Sha256};

pub(crate) fn content_hash(
    identity: &[u8],
    files: &[(&str, &[u8])],
) -> Result<String, &'static str> {
    if files.is_empty()
        || files.len() > 128
        || files.iter().map(|(_, bytes)| bytes.len()).sum::<usize>() > 4 * 1024 * 1024
    {
        return Err("call worker source table exceeds its capacity");
    }
    let mut digest = Sha256::new();
    digest.update(b"RemoteCoder call worker v1\0");
    digest.update(identity);
    digest.update([0]);
    let mut previous = "";
    for (path, bytes) in files {
        if *path <= previous
            || path.contains(['\0', '\\'])
            || path
                .split('/')
                .any(|part| part.is_empty() || part == ".." || part == ".")
        {
            return Err("call worker paths must be unique ordered relative paths");
        }
        previous = path;
        digest.update(path.as_bytes());
        digest.update([0]);
        digest.update((bytes.len() as u64).to_be_bytes());
        digest.update(bytes);
    }
    Ok(format!("{:x}", digest.finalize()))
}
