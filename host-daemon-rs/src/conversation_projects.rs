use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::Serialize;
use tokio::sync::{Mutex, Semaphore};

pub(crate) const MAXIMUM_DIRECTORIES_PER_REQUEST: usize = 500;
const CACHE_CAPACITY: usize = 2_048;
const CACHE_LIFETIME: Duration = Duration::from_secs(10 * 60);
const GIT_TIMEOUT: Duration = Duration::from_secs(5);
const CONCURRENT_RESOLUTIONS: usize = 4;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ProjectKind {
    Remote,
    Repository,
    Directory,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectIdentity {
    pub cwd: String,
    pub kind: ProjectKind,
    pub key: String,
    pub name: String,
    pub root: String,
}

struct Cached {
    identity: ProjectIdentity,
    resolved_at: Instant,
}

pub(crate) struct ProjectResolver {
    cache: Mutex<HashMap<String, Cached>>,
    admission: Arc<Semaphore>,
}

impl Default for ProjectResolver {
    fn default() -> Self {
        Self {
            cache: Mutex::new(HashMap::new()),
            admission: Arc::new(Semaphore::new(CONCURRENT_RESOLUTIONS)),
        }
    }
}

impl ProjectResolver {
    pub(crate) async fn resolve(&self, directories: Vec<String>) -> Result<Vec<ProjectIdentity>> {
        if directories.len() > MAXIMUM_DIRECTORIES_PER_REQUEST {
            bail!("at most {MAXIMUM_DIRECTORIES_PER_REQUEST} directories per request");
        }
        let mut unique = directories;
        unique.sort();
        unique.dedup();
        let now = Instant::now();
        let (mut resolved, missing) = {
            let cache = self.cache.lock().await;
            let mut resolved = Vec::with_capacity(unique.len());
            let mut missing = Vec::new();
            for directory in unique {
                match cache.get(&directory) {
                    Some(cached) if now.duration_since(cached.resolved_at) < CACHE_LIFETIME => {
                        resolved.push(cached.identity.clone());
                    }
                    _ => missing.push(directory),
                }
            }
            (resolved, missing)
        };
        let mut tasks = tokio::task::JoinSet::new();
        for directory in missing {
            let admission = Arc::clone(&self.admission);
            tasks.spawn(async move {
                let _permit = admission.acquire_owned().await?;
                Ok::<_, anyhow::Error>(identify(&directory).await)
            });
        }
        let mut fresh = Vec::new();
        while let Some(result) = tasks.join_next().await {
            fresh.extend(result.context("project resolution worker failed")??);
        }
        let mut cache = self.cache.lock().await;
        if cache.len() + fresh.len() > CACHE_CAPACITY {
            cache.retain(|_, cached| now.duration_since(cached.resolved_at) < CACHE_LIFETIME);
            if cache.len() + fresh.len() > CACHE_CAPACITY {
                cache.clear();
            }
        }
        for identity in &fresh {
            cache.insert(
                identity.cwd.clone(),
                Cached {
                    identity: identity.clone(),
                    resolved_at: now,
                },
            );
        }
        drop(cache);
        resolved.extend(fresh);
        resolved.sort_by(|a, b| a.cwd.cmp(&b.cwd));
        Ok(resolved)
    }
}

async fn identify(directory: &str) -> Option<ProjectIdentity> {
    let GitOutput::Succeeded(lines) = git(
        directory,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--show-toplevel",
            "--git-common-dir",
        ],
    )
    .await?
    else {
        return Some(directory_identity(directory));
    };
    let mut lines = lines.lines();
    let (Some(toplevel), Some(common)) = (lines.next(), lines.next()) else {
        return Some(directory_identity(directory));
    };
    let root = repository_root(toplevel, common);
    if let GitOutput::Succeeded(url) =
        git(directory, &["config", "--get", "remote.origin.url"]).await?
        && let Some(remote) = normalized_remote(url.trim())
    {
        let name = remote.rsplit('/').next().unwrap_or(&remote).to_string();
        return Some(ProjectIdentity {
            cwd: directory.to_string(),
            kind: ProjectKind::Remote,
            key: remote,
            name,
            root,
        });
    }
    Some(ProjectIdentity {
        cwd: directory.to_string(),
        kind: ProjectKind::Repository,
        key: common.to_string(),
        name: last_component(&root),
        root,
    })
}

fn directory_identity(directory: &str) -> ProjectIdentity {
    ProjectIdentity {
        cwd: directory.to_string(),
        kind: ProjectKind::Directory,
        key: directory.to_string(),
        name: last_component(directory),
        root: directory.to_string(),
    }
}

fn repository_root(toplevel: &str, common: &str) -> String {
    let common = Path::new(common);
    match (
        common.file_name().and_then(|name| name.to_str()),
        common.parent(),
    ) {
        (Some(".git"), Some(parent)) => parent.to_string_lossy().into_owned(),
        _ => toplevel.to_string(),
    }
}

fn last_component(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .map_or_else(|| path.to_string(), str::to_string)
}

fn normalized_remote(url: &str) -> Option<String> {
    if url.is_empty() {
        return None;
    }
    let without_scheme = url.split_once("://").map_or(url, |(_, rest)| rest);
    let without_user = without_scheme
        .rsplit_once('@')
        .map_or(without_scheme, |(_, rest)| rest);
    let (host, path) = if url.contains("://") {
        without_user.split_once('/')?
    } else {
        without_user.split_once(':')?
    };
    let host = host.split(':').next()?.to_ascii_lowercase();
    let path = path
        .trim_matches('/')
        .strip_suffix(".git")
        .unwrap_or(path.trim_matches('/'));
    if host.is_empty() || path.is_empty() {
        return None;
    }
    Some(format!("{host}/{path}"))
}

enum GitOutput {
    Succeeded(String),
    Failed,
}

async fn git(directory: &str, arguments: &[&str]) -> Option<GitOutput> {
    let output = tokio::time::timeout(
        GIT_TIMEOUT,
        tokio::process::Command::new("/usr/bin/git")
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .env("GIT_TERMINAL_PROMPT", "0")
            .kill_on_drop(true)
            .output(),
    )
    .await;
    match output {
        Ok(Ok(output)) if output.status.success() => {
            Some(String::from_utf8(output.stdout).map_or(GitOutput::Failed, GitOutput::Succeeded))
        }
        Ok(Ok(_)) => Some(GitOutput::Failed),
        Ok(Err(error)) => {
            tracing::warn!(directory, %error, "git could not run for project resolution");
            None
        }
        Err(_) => {
            tracing::warn!(directory, "git timed out resolving a project");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remotes_normalize_across_ssh_https_and_suffixes() {
        for url in [
            "git@github.com:emileberhard/RemoteCoder.git",
            "https://github.com/emileberhard/RemoteCoder",
            "https://token@GitHub.com/emileberhard/RemoteCoder.git/",
            "ssh://git@github.com:22/emileberhard/RemoteCoder.git",
        ] {
            assert_eq!(
                normalized_remote(url).as_deref(),
                Some("github.com/emileberhard/RemoteCoder"),
                "{url}"
            );
        }
        assert_eq!(normalized_remote(""), None);
        assert_eq!(normalized_remote("/local/path"), None);
    }

    #[test]
    fn a_linked_worktree_names_its_main_repository() {
        assert_eq!(
            repository_root("/work/drawer-views", "/Users/developer/RemoteCoder/.git"),
            "/Users/developer/RemoteCoder"
        );
        assert_eq!(
            repository_root("/bare/checkout", "/repos/bare.git"),
            "/bare/checkout"
        );
    }

    #[tokio::test]
    async fn a_directory_outside_any_repository_is_its_own_project() {
        let _diagnostics =
            tracing::subscriber::set_default(tracing_subscriber::fmt().with_test_writer().finish());
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_string_lossy().into_owned();
        let resolved = ProjectResolver::default()
            .resolve(vec![path.clone(), path.clone()])
            .await
            .unwrap();
        assert_eq!(resolved.len(), 1);
        assert_eq!(resolved[0].kind, ProjectKind::Directory);
        assert_eq!(resolved[0].key, path);
    }
}
