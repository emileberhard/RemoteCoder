use std::fs;
use std::os::unix::fs::MetadataExt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FileRevision {
    device: u64,
    inode: u64,
    pub length: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}

impl From<fs::Metadata> for FileRevision {
    fn from(metadata: fs::Metadata) -> Self {
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            length: metadata.len(),
            modified: (metadata.mtime(), metadata.mtime_nsec()),
            changed: (metadata.ctime(), metadata.ctime_nsec()),
        }
    }
}

impl FileRevision {
    pub(crate) fn can_reuse(&self, current: &Self, sampled: tokio::time::Instant) -> bool {
        self == current
            && (!cfg!(target_os = "linux") || sampled.elapsed() < std::time::Duration::from_secs(1))
    }
}
