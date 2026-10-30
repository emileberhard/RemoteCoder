use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

pub(crate) const O_CLOFORK: libc::c_int = 0x0800_0000;

pub(crate) fn open(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | O_CLOFORK)
        .open(path)
}

#[cfg(test)]
mod tests {
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;

    use crate::storage::no_follow::Root;

    #[test]
    fn a_forked_child_never_inherits_a_held_lock() {
        let directory = tempfile::tempdir().unwrap();
        let opened = super::open(&directory.path().join("opened.lock")).unwrap();
        opened.try_lock().unwrap();
        let rooted = Root::open(directory.path())
            .unwrap()
            .lock_file(&directory.path().join("rooted.lock"))
            .unwrap();
        let descriptors = [opened.as_raw_fd(), rooted.as_raw_fd()];
        let mut command = std::process::Command::new("/usr/bin/true");
        unsafe {
            command.pre_exec(move || {
                for descriptor in descriptors {
                    if libc::fcntl(descriptor, libc::F_GETFD) != -1 {
                        return Err(std::io::Error::other("lock descriptor survived fork"));
                    }
                }
                Ok(())
            });
        }
        assert!(command.status().unwrap().success());
    }
}
