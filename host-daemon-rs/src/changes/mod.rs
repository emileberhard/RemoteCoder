pub(crate) mod checkouts;
mod patch;
pub(crate) mod turn;

use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use patch::{Budgets, ChangedFile, PatchSplitter};

const READ_TIMEOUT: Duration = Duration::from_secs(30);
const CONCURRENT_READS: usize = 2;
const BUDGETS: Budgets = Budgets {
    file_patch_bytes: 256 * 1024,
    hunk_bytes: 4 * 1024 * 1024,
    response_bytes: 6 * 1024 * 1024,
    files: 2_000,
};
const MAXIMUM_DIFF_OUTPUT_BYTES: usize = 256 * 1024 * 1024;
const MAXIMUM_UNTRACKED_LIST_BYTES: usize = 16 * 1024 * 1024;
const MAXIMUM_COMMAND_OUTPUT_BYTES: usize = 64 * 1024;
const MAXIMUM_REFLOG_BYTES: usize = 1024 * 1024;
const BASE_CANDIDATES: [&str; 4] = [
    "refs/remotes/origin/main",
    "refs/remotes/origin/master",
    "refs/heads/main",
    "refs/heads/master",
];
const READ_ONLY_CONFIGURATION: [&str; 6] = [
    "-c",
    "core.splitIndex=false",
    "-c",
    "splitIndex.sharedIndexExpire=never",
    "-c",
    "core.fsmonitor=false",
];

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Source {
    Uncommitted,
    Staged,
    Unstaged,
    Branch,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadRequest {
    pub directory: String,
    pub source: Source,
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub(crate) enum ChangeRead {
    Ready { snapshot: Snapshot },
    Unavailable { reason: Unavailability },
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Unavailability {
    MissingDirectory,
    NotRepository,
    NoBaseBranch,
    NoMergeBase,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub source: Source,
    pub root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    pub captured_at_ms: i64,
    pub files: Vec<ChangedFile>,
    pub unlisted_files: u64,
    pub complete: bool,
}

pub(crate) struct ChangeReader {
    admission: Arc<Semaphore>,
}

#[derive(Clone)]
pub(crate) struct Admission {
    _permit: Arc<OwnedSemaphorePermit>,
}

impl Admission {
    pub(crate) async fn blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> Result<T> {
        let held = self.clone();
        Ok(tokio::task::spawn_blocking(move || {
            let _held = held;
            work()
        })
        .await?)
    }
}

impl Default for ChangeReader {
    fn default() -> Self {
        Self {
            admission: Arc::new(Semaphore::new(CONCURRENT_READS)),
        }
    }
}

impl ChangeReader {
    pub(crate) async fn read(&self, request: ReadRequest) -> Result<ChangeRead> {
        self.admit(|_| {
            read(
                Path::new(&request.directory),
                Comparison::Selected(request.source),
                BUDGETS,
            )
        })
        .await
    }

    pub(crate) async fn admit<T, F: Future<Output = Result<T>>>(
        &self,
        work: impl FnOnce(Admission) -> F,
    ) -> Result<T> {
        tokio::time::timeout(READ_TIMEOUT, async {
            let admission = Admission {
                _permit: Arc::new(self.admission.clone().acquire_owned().await?),
            };
            work(admission.clone()).await
        })
        .await
        .map_err(|_| {
            anyhow!(
                "Reading changes took longer than {} seconds",
                READ_TIMEOUT.as_secs()
            )
        })?
    }
}

#[derive(Clone, Copy)]
enum Comparison {
    Selected(Source),
    Summary,
}

pub(crate) async fn summary(directory: &Path) -> Result<ChangeRead> {
    read(
        directory,
        Comparison::Summary,
        Budgets {
            file_patch_bytes: 0,
            hunk_bytes: 0,
            ..BUDGETS
        },
    )
    .await
}

async fn read(directory: &Path, comparison: Comparison, budgets: Budgets) -> Result<ChangeRead> {
    if !tokio::fs::metadata(directory)
        .await
        .is_ok_and(|metadata| metadata.is_dir())
    {
        return Ok(ChangeRead::Unavailable {
            reason: Unavailability::MissingDirectory,
        });
    }
    let Some(root) = repository_root(directory).await? else {
        return Ok(ChangeRead::Unavailable {
            reason: Unavailability::NotRepository,
        });
    };
    let (head, branch) = tokio::try_join!(
        optional_output(&root, &["rev-parse", "-q", "--verify", "HEAD^{commit}"]),
        optional_output(&root, &["symbolic-ref", "-q", "HEAD"]),
    )?;
    let mut source = match comparison {
        Comparison::Selected(source) => source,
        Comparison::Summary => Source::Branch,
    };
    let branch_base = if source == Source::Branch {
        branch_base(&root, branch.as_deref(), head.is_some()).await?
    } else {
        None
    };
    if matches!(comparison, Comparison::Summary)
        && branch_base
            .as_ref()
            .is_none_or(|base| base.is_head || base.merge_base.is_none())
    {
        source = Source::Uncommitted;
    }
    let (comparison, base) = match source {
        Source::Staged => ("--cached".to_string(), None),
        Source::Unstaged => (String::new(), None),
        Source::Uncommitted => match head {
            Some(head) => (head, None),
            None => (
                required_output(&root, &["hash-object", "-t", "tree", "/dev/null"]).await?,
                None,
            ),
        },
        Source::Branch => {
            let Some(base) = branch_base else {
                return Ok(ChangeRead::Unavailable {
                    reason: Unavailability::NoBaseBranch,
                });
            };
            let Some(commit) = base.merge_base else {
                return Ok(ChangeRead::Unavailable {
                    reason: Unavailability::NoMergeBase,
                });
            };
            (commit, Some(base.display))
        }
    };
    let index = match source {
        Source::Staged => None,
        Source::Unstaged | Source::Uncommitted | Source::Branch => {
            Some(PrivateIndex::with_untracked(&root).await?)
        }
    };
    let captured_at_ms = crate::time::unix_millis();
    let diff = diff(&root, &comparison, index.as_ref(), budgets).await?;
    Ok(ChangeRead::Ready {
        snapshot: Snapshot {
            source,
            root: root.to_string_lossy().into_owned(),
            branch: branch.map(|branch| short_name(&branch)),
            base,
            captured_at_ms,
            complete: diff.complete && diff.split.unlisted_files == 0,
            unlisted_files: diff.split.unlisted_files,
            files: diff.split.files,
        },
    })
}

async fn repository_root(directory: &Path) -> Result<Option<PathBuf>> {
    let output = collect(
        git(
            directory,
            &["rev-parse", "--path-format=absolute", "--show-toplevel"],
        ),
        &[],
        MAXIMUM_COMMAND_OUTPUT_BYTES,
    )
    .await?;
    if output.status.success() {
        let root =
            String::from_utf8(output.stdout).context("Git reported a non-UTF-8 repository path")?;
        return Ok(Some(PathBuf::from(root.trim_end_matches('\n'))));
    }
    let message = String::from_utf8_lossy(&output.stderr);
    if message.contains("not a git repository") || message.contains("must be run in a work tree") {
        return Ok(None);
    }
    bail!("Git could not read the repository: {}", message.trim())
}

async fn default_base(root: &Path) -> Result<Option<String>> {
    let symbolic =
        optional_output(root, &["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]).await?;
    for reference in symbolic
        .into_iter()
        .chain(BASE_CANDIDATES.map(String::from))
    {
        let commit = format!("{reference}^{{commit}}");
        if optional_output(root, &["rev-parse", "-q", "--verify", &commit])
            .await?
            .is_some()
        {
            return Ok(Some(reference));
        }
    }
    Ok(None)
}

struct BranchBase {
    display: String,
    merge_base: Option<String>,
    is_head: bool,
}

async fn branch_base(
    root: &Path,
    branch: Option<&str>,
    has_head: bool,
) -> Result<Option<BranchBase>> {
    let default = default_base(root).await?;
    let start = match branch.filter(|_| has_head) {
        Some(branch) => branch_start(root, branch).await?,
        None => None,
    };
    let reference = if let Some((commit, name)) = start {
        let resolved = optional_output(
            root,
            &[
                "rev-parse",
                "-q",
                "--verify",
                "--symbolic-full-name",
                "--end-of-options",
                &name,
            ],
        )
        .await?;
        match resolved.filter(|reference| {
            reference.starts_with("refs/") && Some(reference.as_str()) != branch
        }) {
            Some(reference) => Some(reference),
            None => {
                let start_ahead = commits_ahead(root, &commit).await?;
                let default_ahead = match &default {
                    Some(reference) => commits_ahead(root, reference).await?,
                    None => None,
                };
                if start_ahead.is_some() && (default_ahead.is_none() || start_ahead < default_ahead)
                {
                    Some(commit)
                } else {
                    default
                }
            }
        }
    } else {
        default
    };
    let Some(reference) = reference else {
        return Ok(None);
    };
    let is_head = branch.is_some_and(|branch| {
        reference == branch
            || branch.strip_prefix("refs/heads/").is_some_and(|name| {
                reference
                    .strip_prefix("refs/remotes/")
                    .and_then(|remote| remote.split_once('/'))
                    .is_some_and(|(_, remote_name)| remote_name == name)
            })
    });
    let display = if reference.starts_with("refs/") {
        short_name(&reference)
    } else {
        required_output(root, &["rev-parse", "--short", &reference]).await?
    };
    let merge_base = if has_head {
        optional_output(root, &["merge-base", "HEAD", &reference]).await?
    } else {
        None
    };
    Ok(Some(BranchBase {
        display,
        merge_base,
        is_head,
    }))
}

async fn commits_ahead(root: &Path, reference: &str) -> Result<Option<u64>> {
    let Some(base) = optional_output(root, &["merge-base", "HEAD", reference]).await? else {
        return Ok(None);
    };
    let count = required_output(root, &["rev-list", "--count", &format!("{base}..HEAD")]).await?;
    Ok(Some(
        count
            .parse()
            .context("Git reported an invalid commit count")?,
    ))
}

async fn branch_start(root: &Path, branch: &str) -> Result<Option<(String, String)>> {
    let mut line = Vec::new();
    let mut bytes = 0;
    let mut found = None;
    let finished = run(
        git(root, &["reflog", "show", "--format=%H%x09%gs", branch]),
        &[],
        |chunk| {
            for byte in chunk {
                bytes += 1;
                if bytes > MAXIMUM_REFLOG_BYTES {
                    return false;
                }
                if *byte == b'\n' {
                    if let Ok(text) = std::str::from_utf8(&line)
                        && let Some((commit, subject)) = text.split_once('\t')
                        && let Some(name) = subject
                            .strip_prefix("branch: Created from ")
                            .or_else(|| subject.strip_prefix("branch: Reset to "))
                    {
                        found = Some((commit.to_owned(), name.to_owned()));
                        return false;
                    }
                    line.clear();
                } else {
                    line.push(*byte);
                }
            }
            true
        },
    )
    .await?;
    if !finished.cut && !finished.status.success() {
        bail!(
            "Git could not read the branch start point: {}",
            String::from_utf8_lossy(&finished.stderr).trim()
        );
    }
    Ok(found)
}

fn short_name(reference: &str) -> String {
    reference
        .strip_prefix("refs/remotes/")
        .or_else(|| reference.strip_prefix("refs/heads/"))
        .unwrap_or(reference)
        .to_string()
}

struct PrivateIndex {
    directory: tempfile::TempDir,
    alternate_objects: String,
}

impl PrivateIndex {
    async fn with_untracked(root: &Path) -> Result<Self> {
        let paths = required_output(
            root,
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "index",
                "--git-path",
                "objects",
            ],
        )
        .await?;
        let mut paths = paths.lines();
        let (Some(index), Some(objects)) = (paths.next(), paths.next()) else {
            bail!("Git did not report its index and object paths");
        };
        let directory = tempfile::Builder::new()
            .prefix("remote-coder-changes-")
            .tempdir()
            .context("Could not create a private Git index")?;
        tokio::fs::create_dir(directory.path().join("objects"))
            .await
            .context("Could not create a private Git object store")?;
        match tokio::fs::copy(index, directory.path().join("index")).await {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("Could not copy the Git index"),
        }
        let index = Self {
            directory,
            alternate_objects: format!(
                "\"{}\"",
                objects.replace('\\', "\\\\").replace('"', "\\\"")
            ),
        };
        if !index.add_untracked(root).await? && !index.add_untracked(root).await? {
            bail!("Untracked files kept disappearing while the changes were read");
        }
        Ok(index)
    }

    async fn add_untracked(&self, root: &Path) -> Result<bool> {
        let listed = collect(
            self.command(root, &["ls-files", "--others", "--exclude-standard", "-z"]),
            &[],
            MAXIMUM_UNTRACKED_LIST_BYTES,
        )
        .await?;
        if !listed.complete {
            bail!("Too many untracked files to review");
        }
        if !listed.status.success() {
            bail!(
                "Git could not list untracked files: {}",
                String::from_utf8_lossy(&listed.stderr).trim()
            );
        }
        let files: Vec<u8> = listed
            .stdout
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty() && !path.ends_with(b"/"))
            .flat_map(|path| path.iter().copied().chain([0]))
            .collect();
        if files.is_empty() {
            return Ok(true);
        }
        let mut add = self.command(
            root,
            &[
                "add",
                "--intent-to-add",
                "--ignore-errors",
                "--pathspec-from-file=-",
                "--pathspec-file-nul",
            ],
        );
        add.env("GIT_LITERAL_PATHSPECS", "1");
        let added = collect(add, &files, MAXIMUM_COMMAND_OUTPUT_BYTES).await?;
        if added.status.success() {
            return Ok(true);
        }
        let message = String::from_utf8_lossy(&added.stderr);
        if message.contains("did not match any files") {
            return Ok(false);
        }
        bail!("Git could not include untracked files: {}", message.trim())
    }

    fn command(&self, root: &Path, arguments: &[&str]) -> Command {
        let mut command = git(root, arguments);
        command
            .env("GIT_INDEX_FILE", self.directory.path().join("index"))
            .env(
                "GIT_OBJECT_DIRECTORY",
                self.directory.path().join("objects"),
            )
            .env("GIT_ALTERNATE_OBJECT_DIRECTORIES", &self.alternate_objects);
        command
    }
}

struct Diff {
    split: patch::SplitPatch,
    complete: bool,
}

async fn diff(
    root: &Path,
    comparison: &str,
    index: Option<&PrivateIndex>,
    budgets: Budgets,
) -> Result<Diff> {
    let mut arguments = vec![
        "-c",
        "core.quotePath=false",
        "-c",
        "diff.suppressBlankEmpty=false",
        "diff",
    ];
    if !comparison.is_empty() {
        arguments.push(comparison);
    }
    arguments.extend([
        "--find-renames",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--unified=3",
        "--no-relative",
        "--submodule=short",
        "--",
    ]);
    let command = match index {
        Some(index) => index.command(root, &arguments),
        None => git(root, &arguments),
    };
    let mut splitter = PatchSplitter::new(budgets);
    let mut read_bytes = 0;
    let finished = run(command, &[], |chunk| {
        read_bytes += chunk.len();
        splitter.push(chunk);
        read_bytes < MAXIMUM_DIFF_OUTPUT_BYTES
    })
    .await?;
    if !finished.cut && !finished.status.success() {
        bail!(
            "Git could not compare the changes: {}",
            String::from_utf8_lossy(&finished.stderr).trim()
        );
    }
    Ok(Diff {
        split: splitter.finish(),
        complete: !finished.cut,
    })
}

fn git(directory: &Path, arguments: &[&str]) -> Command {
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(directory)
        .args(READ_ONLY_CONFIGURATION)
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .kill_on_drop(true);
    command
}

async fn optional_output(directory: &Path, arguments: &[&str]) -> Result<Option<String>> {
    let output = collect(git(directory, arguments), &[], MAXIMUM_COMMAND_OUTPUT_BYTES).await?;
    if output.status.code() == Some(1) {
        return Ok(None);
    }
    let text = output.text(arguments)?;
    Ok((!text.is_empty()).then_some(text))
}

async fn required_output(directory: &Path, arguments: &[&str]) -> Result<String> {
    collect(git(directory, arguments), &[], MAXIMUM_COMMAND_OUTPUT_BYTES)
        .await?
        .text(arguments)
}

struct Collected {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    complete: bool,
}

impl Collected {
    fn text(self, arguments: &[&str]) -> Result<String> {
        if !self.status.success() {
            bail!(
                "git {} failed: {}",
                arguments.first().copied().unwrap_or_default(),
                String::from_utf8_lossy(&self.stderr).trim()
            );
        }
        let text = String::from_utf8(self.stdout).context("Git reported non-UTF-8 output")?;
        Ok(text.trim_end_matches('\n').to_string())
    }
}

async fn collect(command: Command, input: &[u8], limit: usize) -> Result<Collected> {
    let mut stdout = Vec::new();
    let finished = run(command, input, |chunk| {
        let room = limit - stdout.len();
        stdout.extend_from_slice(&chunk[..chunk.len().min(room)]);
        chunk.len() <= room
    })
    .await?;
    Ok(Collected {
        status: finished.status,
        stdout,
        stderr: finished.stderr,
        complete: !finished.cut,
    })
}

struct Finished {
    status: ExitStatus,
    stderr: Vec<u8>,
    cut: bool,
}

async fn run(
    mut command: Command,
    input: &[u8],
    mut sink: impl FnMut(&[u8]) -> bool,
) -> Result<Finished> {
    command
        .process_group(0)
        .stdin(if input.is_empty() {
            Stdio::null()
        } else {
            Stdio::piped()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().context("Git could not run")?;
    let mut group = ProcessGroup(
        child
            .id()
            .and_then(|pid| i32::try_from(pid).ok())
            .map(Pid::from_raw),
    );
    let stdin = child.stdin.take();
    let mut stdout = child.stdout.take().context("Git output is unavailable")?;
    let stderr = child.stderr.take().context("Git errors are unavailable")?;
    let write = async {
        let Some(mut stdin) = stdin else {
            return Ok(());
        };
        match stdin.write_all(input).await {
            Err(error) if error.kind() != std::io::ErrorKind::BrokenPipe => Err(error),
            _ => Ok(()),
        }
    };
    let read = async {
        let mut buffer = vec![0; 64 * 1024];
        loop {
            let count = match stdout.read(&mut buffer).await {
                Ok(count) => count,
                Err(error) => {
                    group.kill();
                    return Err(error);
                }
            };
            if count == 0 {
                return Ok(false);
            }
            if !sink(&buffer[..count]) {
                group.kill();
                return Ok(true);
            }
        }
    };
    let (written, cut, stderr) = tokio::join!(write, read, drain(stderr));
    let cut = cut.context("Could not read Git output")?;
    let stderr = stderr.context("Could not read Git errors")?;
    let status = child.wait().await.context("Git did not finish")?;
    group.release();
    written.context("Could not pass input to Git")?;
    Ok(Finished {
        status,
        stderr,
        cut,
    })
}

async fn drain(mut reader: impl AsyncRead + Unpin) -> std::io::Result<Vec<u8>> {
    let mut kept = Vec::new();
    let mut buffer = vec![0; 8 * 1024];
    loop {
        let count = reader.read(&mut buffer).await?;
        if count == 0 {
            return Ok(kept);
        }
        let room = MAXIMUM_COMMAND_OUTPUT_BYTES - kept.len();
        kept.extend_from_slice(&buffer[..count.min(room)]);
    }
}

struct ProcessGroup(Option<Pid>);

impl ProcessGroup {
    fn kill(&self) {
        if let Some(group) = self.0 {
            let _ = killpg(group, Signal::SIGKILL);
        }
    }

    fn release(&mut self) {
        self.0 = None;
    }
}

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        self.kill();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::FutureExt;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[tokio::test]
    async fn a_read_beyond_the_limit_waits_for_a_slot() {
        let reader = ChangeReader::default();
        let (finish, finished) = tokio::sync::oneshot::channel::<()>();
        let started = AtomicBool::new(false);
        let mut first = std::pin::pin!(reader.admit(|_| async move {
            finished.await.ok();
            Ok::<_, anyhow::Error>(())
        }));
        let mut second = std::pin::pin!(reader.admit(|_| std::future::pending::<Result<()>>()));
        let mut third = std::pin::pin!(reader.admit(|_| async {
            started.store(true, Ordering::SeqCst);
            Ok::<_, anyhow::Error>(())
        }));

        assert!(first.as_mut().now_or_never().is_none());
        assert!(second.as_mut().now_or_never().is_none());
        assert!(third.as_mut().now_or_never().is_none());
        assert!(!started.load(Ordering::SeqCst));

        finish.send(()).unwrap();
        assert!(first.as_mut().now_or_never().is_some());
        assert!(third.as_mut().now_or_never().is_some());
        assert!(started.load(Ordering::SeqCst));
    }

    struct Repository {
        _directory: tempfile::TempDir,
        root: PathBuf,
    }

    impl Repository {
        fn new() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let root = directory.path().join("repo: sitory");
            std::fs::create_dir(&root).unwrap();
            let repository = Self {
                _directory: directory,
                root,
            };
            repository.git(&["init", "-q", "-b", "main"]);
            repository.git(&["config", "user.email", "tests@example.invalid"]);
            repository.git(&["config", "user.name", "Tests"]);
            repository
        }

        fn git(&self, arguments: &[&str]) {
            let status = std::process::Command::new("git")
                .arg("-C")
                .arg(&self.root)
                .args(["-c", "maintenance.auto=false"])
                .args(arguments)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .status()
                .unwrap();
            assert!(status.success(), "git {arguments:?}");
        }

        fn write(&self, path: &str, contents: &str) {
            let path = self.root.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, contents).unwrap();
        }

        fn commit_all(&self, message: &str) {
            self.git(&["add", "-A"]);
            self.git(&["commit", "-q", "-m", message]);
        }

        fn git_directory(&self) -> Vec<(PathBuf, Vec<u8>)> {
            fn walk(directory: &Path, entries: &mut Vec<(PathBuf, Vec<u8>)>) {
                for entry in std::fs::read_dir(directory).unwrap() {
                    let path = entry.unwrap().path();
                    if path.is_dir() {
                        walk(&path, entries);
                    } else {
                        entries.push((path.clone(), std::fs::read(&path).unwrap()));
                    }
                }
            }
            let mut entries = Vec::new();
            walk(&self.root.join(".git"), &mut entries);
            entries.sort();
            entries
        }

        async fn read(&self, source: Source) -> ChangeRead {
            ChangeReader::default()
                .read(ReadRequest {
                    directory: self.root.to_string_lossy().into_owned(),
                    source,
                })
                .await
                .unwrap()
        }
    }

    fn snapshot(read: ChangeRead) -> Snapshot {
        match read {
            ChangeRead::Ready { snapshot } => snapshot,
            ChangeRead::Unavailable { reason } => panic!("unavailable: {reason:?}"),
        }
    }

    fn headers(snapshot: &Snapshot) -> Vec<&str> {
        snapshot
            .files
            .iter()
            .map(|file| file.patch.lines().next().unwrap())
            .collect()
    }

    #[tokio::test]
    async fn uncommitted_includes_untracked_files_without_writing_the_repository() {
        let repository = Repository::new();
        repository.write("tracked.txt", "one\ntwo\n");
        repository.write(".gitignore", "*.log\n");
        repository.commit_all("initial");
        repository.write("tracked.txt", "one\nTWO\n");
        repository.write("new/created.txt", "hello\n");
        repository.write("ignored.log", "noise\n");
        repository.write("empty.txt", "");
        repository.git(&["config", "core.splitIndex", "true"]);
        repository.git(&["config", "splitIndex.sharedIndexExpire", "now"]);
        repository.git(&["add", "tracked.txt"]);
        repository.git(&["reset", "-q"]);
        let before = repository.git_directory();

        let snapshot = snapshot(repository.read(Source::Uncommitted).await);

        assert!(
            repository.git_directory() == before,
            "the read wrote into .git"
        );
        assert!(snapshot.complete);
        assert_eq!(snapshot.branch.as_deref(), Some("main"));
        assert_eq!(
            headers(&snapshot),
            [
                "diff --git a/empty.txt b/empty.txt",
                "diff --git a/new/created.txt b/new/created.txt",
                "diff --git a/tracked.txt b/tracked.txt",
            ]
        );
        let created = &snapshot.files[1];
        assert!(created.patch.contains("new file mode"));
        assert_eq!((created.additions, created.deletions), (1, 0));
        assert_eq!(
            (snapshot.files[2].additions, snapshot.files[2].deletions),
            (1, 1)
        );
    }

    #[tokio::test]
    async fn reads_never_run_the_fsmonitor_hook() {
        let repository = Repository::new();
        repository.write("a.txt", "a\n");
        repository.commit_all("initial");
        let marker = repository.root.with_file_name("fsmonitor-ran");
        let hook = repository.root.with_file_name("fsmonitor-hook");
        std::fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
        std::fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        repository.git(&["config", "core.fsmonitor", hook.to_str().unwrap()]);
        repository.write("a.txt", "b\n");
        repository.git(&["add", "a.txt"]);
        std::fs::remove_file(&marker).ok();

        snapshot(repository.read(Source::Staged).await);
        snapshot(repository.read(Source::Uncommitted).await);

        assert!(!marker.exists(), "a read ran the fsmonitor hook");
    }

    #[tokio::test]
    async fn nested_repositories_are_left_out_of_untracked_files() {
        let repository = Repository::new();
        repository.write("a.txt", "a\n");
        repository.commit_all("initial");
        std::fs::create_dir(repository.root.join("nested")).unwrap();
        repository.git(&["-C", "nested", "init", "-q"]);
        repository.write("b.txt", "b\n");

        let snapshot = snapshot(repository.read(Source::Uncommitted).await);

        assert_eq!(headers(&snapshot), ["diff --git a/b.txt b/b.txt"]);
    }

    #[tokio::test]
    async fn the_base_branch_is_compared_by_its_full_name() {
        let repository = Repository::new();
        repository.write("a.txt", "base\n");
        repository.commit_all("initial");
        repository.git(&["checkout", "-q", "-b", "feature"]);
        repository.write("a.txt", "feature\n");
        repository.commit_all("feature work");
        repository.git(&["tag", "main"]);

        let snapshot = snapshot(repository.read(Source::Branch).await);

        assert_eq!(snapshot.base.as_deref(), Some("main"));
        assert_eq!(headers(&snapshot), ["diff --git a/a.txt b/a.txt"]);
    }

    #[tokio::test]
    async fn long_error_output_does_not_stop_a_command() {
        let mut command = Command::new("sh");
        command.args(["-c", "head -c 200000 /dev/zero >&2; echo done"]);

        let output = collect(command, &[], MAXIMUM_COMMAND_OUTPUT_BYTES)
            .await
            .unwrap();

        assert!(output.status.success());
        assert_eq!(output.stdout, b"done\n");
        assert_eq!(output.stderr.len(), MAXIMUM_COMMAND_OUTPUT_BYTES);
    }

    #[tokio::test]
    async fn an_abandoned_command_takes_its_helpers_with_it() {
        let directory = tempfile::tempdir().unwrap();
        let marker = directory.path().join("helper");
        let mut command = Command::new("sh");
        command
            .args(["-c", "sleep 30 & echo $! > \"$0\"; wait"])
            .arg(&marker);

        let abandoned = tokio::time::timeout(
            Duration::from_millis(500),
            collect(command, &[], MAXIMUM_COMMAND_OUTPUT_BYTES),
        )
        .await;

        assert!(abandoned.is_err());
        let helper: i32 = std::fs::read_to_string(&marker)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        for _ in 0..50 {
            if nix::sys::signal::kill(Pid::from_raw(helper), None).is_err() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        panic!("helper {helper} outlived its command");
    }

    #[tokio::test]
    async fn staged_and_unstaged_split_the_index() {
        let repository = Repository::new();
        repository.write("a.txt", "a\n");
        repository.write("b.txt", "b\n");
        repository.commit_all("initial");
        repository.write("a.txt", "staged\n");
        repository.git(&["add", "a.txt"]);
        repository.write("b.txt", "unstaged\n");
        repository.write("c.txt", "untracked\n");

        let staged = snapshot(repository.read(Source::Staged).await);
        assert_eq!(headers(&staged), ["diff --git a/a.txt b/a.txt"]);

        let unstaged = snapshot(repository.read(Source::Unstaged).await);
        assert_eq!(
            headers(&unstaged),
            ["diff --git a/b.txt b/b.txt", "diff --git a/c.txt b/c.txt"]
        );
    }

    #[tokio::test]
    async fn branch_compares_the_working_tree_with_the_merge_base() {
        let repository = Repository::new();
        repository.write("a.txt", "base\n");
        repository.commit_all("initial");
        repository.git(&["checkout", "-q", "-b", "feature"]);
        repository.write("a.txt", "committed on the branch\n");
        repository.commit_all("branch work");
        repository.write("b.txt", "not committed yet\n");

        let snapshot = snapshot(repository.read(Source::Branch).await);

        assert_eq!(snapshot.base.as_deref(), Some("main"));
        assert_eq!(
            headers(&snapshot),
            ["diff --git a/a.txt b/a.txt", "diff --git a/b.txt b/b.txt"]
        );
    }

    #[tokio::test]
    async fn a_branch_from_a_nondefault_remote_counts_only_its_work() {
        let repository = Repository::new();
        repository.write("main.txt", "main\n");
        repository.commit_all("initial");
        repository.git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
        repository.git(&[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ]);
        repository.write("develop.txt", "develop\n");
        repository.commit_all("develop work");
        repository.git(&["update-ref", "refs/remotes/origin/develop-9.4", "HEAD"]);
        repository.git(&["checkout", "-q", "-b", "feature", "origin/develop-9.4"]);
        repository.write("feature.txt", "feature\n");
        repository.commit_all("feature work");
        let before = repository.git_directory();

        let snapshot = snapshot(repository.read(Source::Branch).await);

        assert_eq!(snapshot.base.as_deref(), Some("origin/develop-9.4"));
        assert_eq!(
            headers(&snapshot),
            ["diff --git a/feature.txt b/feature.txt"]
        );
        assert!(
            repository.git_directory() == before,
            "the read wrote into .git"
        );
    }

    #[tokio::test]
    async fn a_stacked_switch_branch_counts_only_its_own_work() {
        let repository = Repository::new();
        repository.write("main.txt", "main\n");
        repository.commit_all("initial");
        repository.git(&["switch", "-q", "-c", "feature"]);
        repository.write("feature.txt", "feature\n");
        repository.commit_all("feature work");
        repository.git(&["switch", "-q", "-c", "stack"]);
        repository.write("stack.txt", "stack\n");
        repository.commit_all("stack work");

        let snapshot = snapshot(repository.read(Source::Branch).await);

        assert_eq!(headers(&snapshot), ["diff --git a/stack.txt b/stack.txt"]);
        assert_ne!(snapshot.base.as_deref(), Some("main"));
    }

    #[tokio::test]
    async fn a_switch_branch_rebased_on_new_main_excludes_upstream_commits() {
        let repository = Repository::new();
        repository.write("initial.txt", "initial\n");
        repository.commit_all("initial");
        repository.git(&["switch", "-q", "-c", "feature"]);
        repository.write("feature.txt", "feature\n");
        repository.commit_all("feature work");
        repository.git(&["switch", "-q", "main"]);
        repository.write("upstream.txt", "upstream\n");
        repository.commit_all("upstream work");
        repository.git(&["switch", "-q", "feature"]);
        repository.git(&["rebase", "-q", "main"]);

        let snapshot = snapshot(repository.read(Source::Branch).await);

        assert_eq!(snapshot.base.as_deref(), Some("main"));
        assert_eq!(
            headers(&snapshot),
            ["diff --git a/feature.txt b/feature.txt"]
        );
    }

    #[tokio::test]
    async fn checkout_b_uses_the_newest_start_point_and_ignores_commit_resets() {
        let repository = Repository::new();
        repository.write("initial.txt", "initial\n");
        repository.commit_all("initial");
        repository.git(&["checkout", "-q", "-b", "feature", "main"]);
        repository.git(&["checkout", "-q", "main"]);
        repository.write("develop.txt", "develop\n");
        repository.commit_all("develop work");
        repository.git(&["branch", "develop-9.4"]);
        repository.git(&["checkout", "-q", "-B", "feature", "develop-9.4"]);
        repository.write("feature.txt", "feature\n");
        repository.commit_all("feature work");
        repository.git(&["reset", "-q", "--soft", "HEAD~1"]);

        let snapshot = snapshot(repository.read(Source::Branch).await);

        assert_eq!(snapshot.base.as_deref(), Some("develop-9.4"));
        assert_eq!(
            headers(&snapshot),
            ["diff --git a/feature.txt b/feature.txt"]
        );
    }

    #[tokio::test]
    async fn a_cloned_main_uses_default_base_and_summary_excludes_its_commits() {
        let repository = Repository::new();
        repository.write("initial.txt", "initial\n");
        repository.commit_all("initial");
        let clone = repository.root.with_file_name("clone");
        repository.git(&[
            "clone",
            "-q",
            repository.root.to_str().unwrap(),
            clone.to_str().unwrap(),
        ]);
        let repository = Repository {
            _directory: repository._directory,
            root: clone,
        };
        repository.git(&["config", "user.email", "tests@example.invalid"]);
        repository.git(&["config", "user.name", "Tests"]);
        repository.write("committed.txt", "committed\n");
        repository.commit_all("shared main work");
        repository.write("working.txt", "working\n");

        let branch = snapshot(repository.read(Source::Branch).await);
        assert_eq!(branch.base.as_deref(), Some("origin/main"));
        assert_eq!(branch.files.len(), 2);
        let summary = snapshot(summary(&repository.root).await.unwrap());
        assert_eq!(summary.source, Source::Uncommitted);
        assert_eq!(
            headers(&summary),
            ["diff --git a/working.txt b/working.txt"]
        );
        assert_eq!(
            (summary.files[0].additions, summary.files[0].deletions),
            (1, 0)
        );
        assert!(!summary.files[0].patch.contains("@@"));
    }

    #[tokio::test]
    async fn an_unborn_head_shows_everything_as_new() {
        let repository = Repository::new();
        repository.write("first.txt", "first\n");

        let snapshot = snapshot(repository.read(Source::Uncommitted).await);

        assert_eq!(headers(&snapshot), ["diff --git a/first.txt b/first.txt"]);
        assert!(matches!(
            repository.read(Source::Branch).await,
            ChangeRead::Unavailable {
                reason: Unavailability::NoBaseBranch
            }
        ));
    }

    #[tokio::test]
    async fn unavailable_reads_name_their_reason() {
        let directory = tempfile::tempdir().unwrap();
        let reader = ChangeReader::default();
        let read = |path: PathBuf| {
            reader.read(ReadRequest {
                directory: path.to_string_lossy().into_owned(),
                source: Source::Uncommitted,
            })
        };
        assert!(matches!(
            read(directory.path().to_path_buf()).await.unwrap(),
            ChangeRead::Unavailable {
                reason: Unavailability::NotRepository
            }
        ));
        assert!(matches!(
            read(directory.path().join("missing")).await.unwrap(),
            ChangeRead::Unavailable {
                reason: Unavailability::MissingDirectory
            }
        ));
    }

    #[tokio::test]
    async fn a_clean_tree_is_a_complete_empty_snapshot() {
        let repository = Repository::new();
        repository.write("a.txt", "a\n");
        repository.commit_all("initial");

        let snapshot = snapshot(repository.read(Source::Uncommitted).await);

        assert!(snapshot.files.is_empty());
        assert!(snapshot.complete);
        let wire = serde_json::to_value(ChangeRead::Ready { snapshot }).unwrap();
        assert_eq!(wire["status"], "ready");
        assert_eq!(wire["snapshot"]["source"], "uncommitted");
        assert_eq!(wire["snapshot"]["files"], serde_json::json!([]));
    }
}
