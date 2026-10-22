use super::recovery::RecoveryStore;
use anyhow::{Context, Result};
use std::fs::File;
use std::os::unix::fs::OpenOptionsExt;
use std::time::Duration;

pub(crate) struct ControlOwnerLease {
    file: File,
}

impl Drop for ControlOwnerLease {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

impl ControlOwnerLease {
    pub(crate) fn acquire(store: &RecoveryStore) -> Result<Self> {
        Self::try_acquire(store)?.context("another gateway owns Codex recovery control; wait for that process to exit before restoring ingress")
    }

    fn try_acquire(store: &RecoveryStore) -> Result<Option<Self>> {
        let path = store.path().with_extension("control.lock");
        let parent = path.parent().context("control owner lock has no parent")?;
        crate::storage::private_state::ensure_private_directory(parent)?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("opening control owner lock {}", path.display()))?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self { file })),
            Err(std::fs::TryLockError::WouldBlock) => Ok(None),
            Err(std::fs::TryLockError::Error(error)) => {
                Err(error).with_context(|| format!("locking control owner {}", path.display()))
            }
        }
    }
}

pub(super) async fn wait_for_control_owner_exit(
    store: &RecoveryStore,
    timeout: Duration,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if let Some(_owner) = ControlOwnerLease::try_acquire(store)? {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            anyhow::bail!(
                "timed out waiting for Codex recovery control owner to exit; ingress remains fenced, retry after that gateway process exits"
            );
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use std::io::{BufRead, Read, Write};
    use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};

    pub(in crate::runtime) struct ControlOwnerChild {
        child: Child,
        pub(in crate::runtime) stdin: Option<ChildStdin>,
    }

    impl ControlOwnerChild {
        pub(in crate::runtime) fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
            self.child.try_wait()
        }

        pub(in crate::runtime) fn wait(&mut self) -> std::io::Result<ExitStatus> {
            self.child.wait()
        }
    }

    impl Drop for ControlOwnerChild {
        fn drop(&mut self) {
            self.stdin.take();
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    #[test]
    #[ignore]
    fn control_owner_child() {
        let store = RecoveryStore::new(
            std::env::var_os("RC_TEST_CONTROL_OWNER_STORE")
                .map(std::path::PathBuf::from)
                .expect("isolated control store"),
        );
        let _owner = ControlOwnerLease::acquire(&store).expect("child control owner");
        println!("control-owner-ready");
        std::io::stdout().flush().expect("ready handshake");
        std::io::stdin()
            .read_exact(&mut [0_u8])
            .expect("owner release");
    }

    pub(in crate::runtime) fn hold_control_in_child(store: &RecoveryStore) -> ControlOwnerChild {
        let mut owner = ControlOwnerChild {
            child: child_command(store)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .expect("independent control owner"),
            stdin: None,
        };
        owner.stdin = owner.child.stdin.take();
        let mut output = std::io::BufReader::new(owner.child.stdout.take().expect("child stdout"));
        let mut line = String::new();
        loop {
            line.clear();
            assert!(
                output.read_line(&mut line).expect("owner handshake") > 0,
                "control owner exited without acquiring its lease"
            );
            if line.trim() == "control-owner-ready" {
                owner.child.stdout = Some(output.into_inner());
                return owner;
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn replacement_waits_for_process_lease_release_and_times_out_while_owner_lives() {
        let root = tempfile::tempdir().expect("isolated control state");
        let store = RecoveryStore::new(root.path().join("state/recovery.json"));
        let mut owner = hold_control_in_child(&store);
        let failure = wait_for_control_owner_exit(&store, Duration::from_millis(250))
            .await
            .expect_err("live process must prevent replacement");
        assert!(failure.to_string().contains("ingress remains fenced"));
        assert!(owner.try_wait().expect("process state").is_none());
        owner
            .stdin
            .take()
            .expect("owner stdin")
            .write_all(b"x")
            .expect("release owner");
        assert!(owner.wait().expect("owner exit").success());
        wait_for_control_owner_exit(&store, Duration::from_millis(250))
            .await
            .expect("observed process exit allows replacement");
        let _replacement = ControlOwnerLease::acquire(&store).expect("replacement owns control");
    }

    fn child_command(store: &RecoveryStore) -> Command {
        let mut command = Command::new(std::env::current_exe().expect("test executable"));
        command
            .args([
                "--exact",
                "runtime::control_owner::tests::control_owner_child",
                "--ignored",
                "--nocapture",
            ])
            .env("RC_TEST_CONTROL_OWNER_STORE", store.path());
        command
    }
}
