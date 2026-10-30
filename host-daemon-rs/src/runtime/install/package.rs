use crate::config::{
    HostPaths, REQUIRED_CODE_MODE_HOST_SHA256, REQUIRED_CODEX_SHA256, REQUIRED_CODEX_SOURCE_COMMIT,
    REQUIRED_CODEX_VERSION,
};
use crate::runtime::recovery::{RecoveryJournal, RecoveryPhase, RecoveryStore, RuntimeSwap};
use crate::storage::private_state::{self, Creation};
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub(in crate::runtime) struct RuntimePaths {
    pub(in crate::runtime) release: PathBuf,
    pub(in crate::runtime) staging: PathBuf,
    pub(in crate::runtime) previous_release: PathBuf,
    pub(in crate::runtime) current: PathBuf,
    pub(in crate::runtime) previous_current: PathBuf,
    pub(in crate::runtime) gateway_env: PathBuf,
    pub(in crate::runtime) previous_gateway_env: PathBuf,
}

impl RuntimePaths {
    pub(in crate::runtime) fn load() -> Result<Self> {
        let paths = HostPaths::from_env()?;
        let standalone = paths.home().join(".codex/packages/standalone");
        let releases = standalone.join("releases");
        Ok(Self {
            release: releases.join(format!("{REQUIRED_CODEX_VERSION}-aarch64-apple-darwin")),
            staging: releases.join(".runtime-staging"),
            previous_release: releases.join(".runtime-previous-release"),
            current: standalone.join("current"),
            previous_current: standalone.join(".runtime-previous-current"),
            gateway_env: paths.state("codex-gateway.env"),
            previous_gateway_env: paths.state("codex-gateway.env.runtime-previous"),
        })
    }
}

pub(super) struct StagedRuntime {
    pub(super) path: PathBuf,
    pub(super) paths: RuntimePaths,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PackageManifest {
    pub(crate) layout_version: u32,
    pub(crate) version: String,
    pub(crate) source_commit: String,
    pub(crate) target: String,
    pub(crate) variant: String,
    pub(crate) entrypoint: String,
    pub(crate) resources_dir: String,
    pub(crate) path_dir: String,
    pub(crate) binaries: HashMap<String, PackageBinary>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PackageBinary {
    pub(crate) sha256: String,
}

pub(in crate::runtime) fn validate_runtime_package(package_dir: &Path) -> Result<PathBuf> {
    let package_dir = package_dir
        .canonicalize()
        .with_context(|| format!("failed to resolve {}", package_dir.display()))?;
    let manifest: PackageManifest = serde_json::from_slice(
        &std::fs::read(package_dir.join("codex-package.json"))
            .context("Codex package manifest is missing")?,
    )
    .context("Codex package manifest is invalid")?;
    if manifest.layout_version != 1
        || manifest.version != REQUIRED_CODEX_VERSION
        || manifest.source_commit != REQUIRED_CODEX_SOURCE_COMMIT
        || manifest.target != "aarch64-apple-darwin"
        || manifest.variant != "codex"
        || manifest.entrypoint != "bin/codex"
        || manifest.resources_dir != "codex-resources"
        || manifest.path_dir != "codex-path"
    {
        bail!("Codex package version, source commit, or target is not approved");
    }
    for (name, approved) in [
        ("bin/codex", REQUIRED_CODEX_SHA256),
        ("bin/codex-code-mode-host", REQUIRED_CODE_MODE_HOST_SHA256),
    ] {
        let declared = manifest
            .binaries
            .get(name)
            .with_context(|| format!("Codex package manifest omits {name}"))?;
        if declared.sha256 != approved || sha256_file(&package_dir.join(name))? != approved {
            bail!("Codex package hash for {name} is not approved");
        }
    }

    Ok(package_dir)
}

pub(super) fn stage_runtime_package(package_dir: &Path) -> Result<StagedRuntime> {
    let package_dir = validate_runtime_package(package_dir)?;
    let paths = RuntimePaths::load()?;
    if paths.staging.exists() {
        bail!(
            "stale runtime staging directory exists: {}",
            paths.staging.display()
        );
    }
    if let Some(parent) = paths.staging.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::create_dir(&paths.staging)?;
    let stage_result = (|| {
        copy_tree_contents(&package_dir, &paths.staging)?;
        let root_codex = paths.staging.join("codex");
        if !root_codex.exists() {
            std::os::unix::fs::symlink("bin/codex", &root_codex)?;
        }
        validate_runtime_package(&paths.staging)?;
        write_installed_approval(&paths.staging)?;
        Ok::<_, anyhow::Error>(())
    })();
    if let Err(error) = stage_result {
        // This invocation created the staging directory under the runtime
        // lease. Leave a pre-existing staging path untouched, but remove our
        // own partial copy so an exact source restore can be retried.
        return match remove_path(&paths.staging) {
            Ok(()) => Err(error),
            Err(cleanup_error) => Err(error).context(format!(
                "removing this invocation's partial staging also failed: {cleanup_error:#}"
            )),
        };
    }
    Ok(StagedRuntime {
        path: paths.staging.clone(),
        paths,
    })
}

fn write_installed_approval(package: &Path) -> Result<()> {
    let approval = serde_json::json!({
        "codexCliVersion": REQUIRED_CODEX_VERSION,
        "codexForkCommit": REQUIRED_CODEX_SOURCE_COMMIT,
        "runtimeHashes": {
            "bin/codex": REQUIRED_CODEX_SHA256,
            "bin/codex-code-mode-host": REQUIRED_CODE_MODE_HOST_SHA256,
        },
    });
    let manifest_sha256 = sha256_file(&package.join("codex-package.json"))?;
    let directory = package
        .parent()
        .context("package has no parent")?
        .join("approvals");
    std::fs::create_dir_all(&directory)?;
    let path = directory.join(format!("{manifest_sha256}.json"));
    let creation = private_state::create_new_with(&path, |file| {
        file.write_all(&serde_json::to_vec_pretty(&approval)?)?;
        file.write_all(b"\n")?;
        file.set_permissions(std::fs::Permissions::from_mode(0o444))?;
        Ok(())
    })?;
    match creation {
        Creation::Created => {}
        Creation::AlreadyExists => {
            let metadata = std::fs::symlink_metadata(&path)?;
            anyhow::ensure!(
                metadata.is_file() && metadata.permissions().mode() & 0o222 == 0,
                "installed Codex approval must be a read-only regular file"
            );
            let actual: serde_json::Value = serde_json::from_slice(&std::fs::read(&path)?)?;
            anyhow::ensure!(
                actual == approval,
                "installed Codex approval does not match this installer"
            );
        }
    }
    Ok(())
}

pub(super) fn activate_staged_runtime(
    store: &RecoveryStore,
    generation_id: &str,
    staged: &StagedRuntime,
) -> Result<RecoveryJournal> {
    let paths = &staged.paths;
    for pending in [
        &paths.previous_release,
        &paths.previous_current,
        &paths.previous_gateway_env,
    ] {
        if path_exists(pending)? {
            bail!(
                "pending runtime rollback artifact exists: {}",
                pending.display()
            );
        }
    }
    let had_release = paths.release.is_dir();
    let had_current = std::fs::symlink_metadata(&paths.current).is_ok();
    let previous_current_target = if had_current {
        Some(std::fs::read_link(&paths.current).with_context(|| {
            format!(
                "managed Codex current path is not a symlink: {}",
                paths.current.display()
            )
        })?)
    } else {
        None
    };
    let had_gateway_env = paths.gateway_env.is_file();
    let source_identity =
        super::super::identity::PackageIdentity::read(&paths.current.join("codex"))?;
    let target_identity =
        super::super::identity::PackageIdentity::read(&staged.path.join("bin/codex"))?;
    let journal = store
        .load()?
        .context("runtime source journal disappeared")?;
    if let Some(expected) = &journal.package_identity {
        anyhow::ensure!(
            expected == &source_identity,
            "source package changed after capture"
        );
    }
    let swap = RuntimeSwap {
        had_release,
        had_current,
        previous_current_target,
        had_gateway_env,
        source_identity: Some(source_identity),
        target_identity: Some(target_identity.clone()),
    };
    store.update(generation_id, |journal| {
        journal.runtime_swap = Some(swap.clone());
        Ok(())
    })?;

    let activation = (|| -> Result<()> {
        if had_release {
            std::fs::rename(&paths.release, &paths.previous_release)?;
        }
        if had_current {
            std::fs::rename(&paths.current, &paths.previous_current)?;
        }
        if had_gateway_env {
            std::fs::copy(&paths.gateway_env, &paths.previous_gateway_env)?;
            std::fs::set_permissions(
                &paths.previous_gateway_env,
                std::fs::Permissions::from_mode(0o600),
            )?;
        }
        std::fs::rename(&staged.path, &paths.release)?;
        std::os::unix::fs::symlink(&paths.release, &paths.current)?;
        if had_gateway_env {
            rewrite_gateway_codex_path(&paths.gateway_env, &paths.current.join("codex"))?;
        }
        fsync_runtime_paths(paths)
    })();
    if let Err(error) = activation {
        let rollback = restore_runtime_paths(paths, &swap);
        return match rollback {
            Ok(()) => {
                store.update(generation_id, |journal| {
                    journal.runtime_swap = None;
                    Ok(())
                })?;
                Err(error).context("runtime activation failed and was rolled back")
            }
            Err(rollback_error) => Err(error).context(format!(
                "runtime activation failed and rollback also failed: {rollback_error:#}"
            )),
        };
    }
    store.update(generation_id, |journal| {
        journal.phase = RecoveryPhase::RuntimeInstalled;
        journal.package_identity = Some(target_identity);
        Ok(())
    })
}

pub(in crate::runtime) fn settle_interrupted_activation(
    store: &RecoveryStore,
    paths: &RuntimePaths,
) -> Result<()> {
    let Some(journal) = store.load()? else {
        return Ok(());
    };
    if journal.phase != RecoveryPhase::DaemonStopped {
        return Ok(());
    }
    let Some(swap) = &journal.runtime_swap else {
        return Ok(());
    };
    let source = swap
        .source_identity
        .as_ref()
        .context("interrupted activation has no source identity")?;
    let target = swap
        .target_identity
        .as_ref()
        .context("interrupted activation has no target identity")?;
    source.verify(&previous_runtime_codex(paths, swap)?)?;
    if path_exists(&paths.current)? && target.verify(&paths.current.join("codex")).is_ok() {
        if swap.had_gateway_env {
            rewrite_gateway_codex_path(&paths.gateway_env, &paths.current.join("codex"))?;
        }
        fsync_runtime_paths(paths)?;
        store.update(&journal.generation_id, |journal| {
            journal.phase = RecoveryPhase::RuntimeInstalled;
            journal.package_identity = Some(target.clone());
            Ok(())
        })?;
    } else {
        restore_runtime_paths(paths, swap)?;
        source.verify(&paths.current.join("codex"))?;
        remove_path(&paths.staging)?;
        store.update(&journal.generation_id, |journal| {
            journal.runtime_swap = None;
            journal.package_identity = Some(source.clone());
            Ok(())
        })?;
    }
    Ok(())
}

pub(in crate::runtime) fn restore_previous_runtime(
    store: &RecoveryStore,
    generation_id: &str,
    paths: &RuntimePaths,
) -> Result<RecoveryJournal> {
    let journal = store
        .load()?
        .context("runtime rollback journal is missing")?;
    let swap = journal
        .runtime_swap
        .clone()
        .context("runtime rollback metadata is missing")?;
    let source = swap
        .source_identity
        .as_ref()
        .context("runtime rollback has no source package identity")?;
    source.verify(&previous_runtime_codex(paths, &swap)?)?;
    restore_runtime_paths(paths, &swap)?;
    store.update(generation_id, |journal| {
        journal.phase = RecoveryPhase::RuntimeInstalled;
        journal.runtime_swap = None;
        journal.package_identity = Some(source.clone());
        Ok(())
    })
}

pub(in crate::runtime) fn previous_runtime_codex(
    paths: &RuntimePaths,
    swap: &RuntimeSwap,
) -> Result<PathBuf> {
    let previous_target = match &swap.previous_current_target {
        Some(target) if target.is_absolute() => Some(target.clone()),
        Some(target) => Some(
            paths
                .current
                .parent()
                .context("runtime current has no parent")?
                .join(target),
        ),
        None => None,
    };
    if previous_target.as_ref() == Some(&paths.release) {
        if path_exists(&paths.previous_release)? {
            Ok(paths.previous_release.join("bin/codex"))
        } else {
            Ok(paths.current.join("codex"))
        }
    } else if path_exists(&paths.previous_current)? {
        Ok(paths.previous_current.join("codex"))
    } else {
        Ok(paths.current.join("codex"))
    }
}

fn restore_runtime_paths(paths: &RuntimePaths, swap: &RuntimeSwap) -> Result<()> {
    if path_exists(&paths.previous_current)? {
        if std::fs::read_link(&paths.previous_current).ok().as_ref()
            != swap.previous_current_target.as_ref()
        {
            bail!("previous Codex current symlink does not match rollback metadata");
        }
        remove_path(&paths.current)?;
        std::fs::rename(&paths.previous_current, &paths.current)?;
    } else if !swap.had_current {
        remove_path(&paths.current)?;
    }
    if path_exists(&paths.previous_release)? {
        remove_path(&paths.release)?;
        std::fs::rename(&paths.previous_release, &paths.release)?;
    } else if !swap.had_release {
        remove_path(&paths.release)?;
    }
    if path_exists(&paths.previous_gateway_env)? {
        std::fs::rename(&paths.previous_gateway_env, &paths.gateway_env)?;
    } else if !swap.had_gateway_env {
        let _ = std::fs::remove_file(&paths.gateway_env);
    }
    fsync_runtime_paths(paths)
}

pub(in crate::runtime) fn commit_runtime_swap(store: &RecoveryStore) -> Result<()> {
    let Some(journal) = store.load()? else {
        return Ok(());
    };
    if journal.phase != RecoveryPhase::Completed {
        bail!("cannot commit an unfinished runtime transaction");
    }
    if journal.runtime_swap.is_none() {
        return Ok(());
    }
    let paths = RuntimePaths::load()?;
    remove_path(&paths.previous_release)?;
    remove_path(&paths.previous_current)?;
    let _ = std::fs::remove_file(&paths.previous_gateway_env);
    fsync_runtime_paths(&paths)?;
    store.update(&journal.generation_id, |journal| {
        journal.runtime_swap = None;
        Ok(())
    })?;
    Ok(())
}

fn rewrite_gateway_codex_path(path: &Path, codex_path: &Path) -> Result<()> {
    let source = std::fs::read_to_string(path)?;
    let replacement = format!("RC_CODEX_GATEWAY_CODEX_PATH={}", codex_path.display());
    let mut found = false;
    let mut lines = source
        .lines()
        .filter_map(|line| {
            let unexported = line.strip_prefix("export ").unwrap_or(line);
            if unexported.starts_with("RC_CODEX_GATEWAY_CODEX_PATH=") {
                if found {
                    return None;
                }
                found = true;
                Some(replacement.clone())
            } else {
                Some(line.to_string())
            }
        })
        .collect::<Vec<_>>();
    if !found {
        lines.push(replacement);
    }
    crate::storage::private_state::replace(path, format!("{}\n", lines.join("\n")).as_bytes())
}

pub(in crate::runtime) fn sha256_file(path: &Path) -> Result<String> {
    let mut file =
        File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    Ok(crate::ids::lower_hex(&hash.finalize()))
}

pub(super) fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    std::fs::create_dir(destination)?;
    copy_tree_contents(source, destination)
}

fn copy_tree_contents(source: &Path, destination: &Path) -> Result<()> {
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_tree(&source_path, &destination_path)?;
        } else if kind.is_symlink() {
            std::os::unix::fs::symlink(std::fs::read_link(&source_path)?, destination_path)?;
        } else if kind.is_file() {
            std::fs::copy(source_path, destination_path)?;
        } else {
            bail!("unsupported package entry {}", source_path.display());
        }
    }
    Ok(())
}

pub(super) fn remove_path(path: &Path) -> Result<()> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_dir() {
        std::fs::remove_dir_all(path)?;
    } else {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

pub(in crate::runtime) fn path_exists(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

fn fsync_runtime_paths(paths: &RuntimePaths) -> Result<()> {
    for parent in [
        paths.current.parent(),
        paths.release.parent(),
        paths.gateway_env.parent(),
    ]
    .into_iter()
    .flatten()
    {
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::identity::{PackageIdentity, write_test_package};
    use crate::runtime::recovery::{RecoveryTask, RecoveryTaskStatus};

    #[test]
    fn installed_approval_is_read_only_idempotent_and_rejects_replacement() {
        let root = tempfile::tempdir().expect("isolated package");
        let package = root.path().join("package");
        std::fs::create_dir(&package).expect("package directory");
        std::fs::write(package.join("codex-package.json"), b"fixture-manifest").expect("manifest");
        let manifest_sha256 =
            sha256_file(&package.join("codex-package.json")).expect("manifest hash");
        write_installed_approval(&package).expect("approval installed");
        let path = root
            .path()
            .join("approvals")
            .join(format!("{manifest_sha256}.json"));
        let original = std::fs::read(&path).expect("approval bytes");
        assert_eq!(
            std::fs::metadata(&path).expect("mode").permissions().mode() & 0o777,
            0o444
        );
        write_installed_approval(&package).expect("same approval retained");
        assert_eq!(std::fs::read(&path).expect("retained bytes"), original);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644))
            .expect("fixture mode");
        std::fs::write(&path, b"{}").expect("divergent fixture");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444))
            .expect("fixture read only");
        assert!(write_installed_approval(&package).is_err());
        assert_eq!(
            std::fs::read(&path).expect("divergent bytes retained"),
            b"{}"
        );
        std::fs::write(
            package.join("codex-package.json"),
            b"different-source-manifest",
        )
        .expect("new manifest");
        write_installed_approval(&package)
            .expect("distinct manifest has independent immutable approval");
        assert_eq!(
            std::fs::read_dir(root.path().join("approvals"))
                .expect("approval directory")
                .count(),
            2
        );
        assert_eq!(
            std::fs::read(path).expect("previous approval retained"),
            b"{}"
        );
    }

    fn fixture(
        root: &Path,
        source_version: &str,
    ) -> (RuntimePaths, StagedRuntime, RecoveryStore, PackageIdentity) {
        let source = root.join("source");
        write_test_package(&source, source_version, "exit 0");
        let paths = RuntimePaths {
            release: root.join("target"),
            staging: root.join("staging"),
            previous_release: root.join("previous-release"),
            current: root.join("current"),
            previous_current: root.join("previous-current"),
            gateway_env: root.join("gateway.env"),
            previous_gateway_env: root.join("gateway.previous.env"),
        };
        std::os::unix::fs::symlink(&source, &paths.current).expect("source selected");
        std::fs::write(
            &paths.gateway_env,
            format!(
                "RC_CODEX_GATEWAY_CODEX_PATH={}\n",
                paths.current.join("codex").display()
            ),
        )
        .expect("env");
        write_test_package(&paths.staging, REQUIRED_CODEX_VERSION, "exit 1");
        let staged = StagedRuntime {
            path: paths.staging.clone(),
            paths: paths.clone(),
        };
        let identity =
            PackageIdentity::read(&paths.current.join("codex")).expect("source identity");
        let store = RecoveryStore::new(root.join("state/recovery.json"));
        let mut journal = RecoveryJournal::new(
            "generation-1".into(),
            "c".repeat(64),
            vec![RecoveryTask {
                thread_id: "exact-thread".into(),
                turn_id: "source-turn".into(),
                parent_thread_id: None,
                depth: 0,
                recovery_attempts: 0,
                status: RecoveryTaskStatus::Suspended,
                error: None,
            }],
        )
        .expect("journal");
        journal.phase = RecoveryPhase::DaemonStopped;
        journal.package_identity = Some(identity.clone());
        store.write(&journal).expect("source stopped");
        (paths, staged, store, identity)
    }

    #[test]
    fn cross_version_activation_and_rollback_preserve_exact_work_and_source_package() {
        let root = tempfile::tempdir().expect("isolated cutover");
        let (paths, staged, store, source) = fixture(root.path(), "0.150.0-alpha.8");
        let installed =
            activate_staged_runtime(&store, "generation-1", &staged).expect("target activated");
        assert_eq!(installed.phase, RecoveryPhase::RuntimeInstalled);
        assert_eq!(installed.tasks[0].turn_id, "source-turn");
        assert_eq!(
            installed
                .runtime_swap
                .as_ref()
                .expect("rollback owner")
                .source_identity
                .as_ref(),
            Some(&source)
        );
        let target = installed
            .package_identity
            .as_ref()
            .expect("target identity");
        assert_eq!(target.version, REQUIRED_CODEX_VERSION);
        target
            .verify(&paths.current.join("codex"))
            .expect("target bytes");
        assert!(source.verify(&paths.current.join("codex")).is_err());
        assert!(
            !paths.previous_release.exists(),
            "different source version stays in its own release"
        );
        let restored =
            restore_previous_runtime(&store, "generation-1", &paths).expect("source restored");
        source
            .verify(&paths.current.join("codex"))
            .expect("exact source bytes");
        assert_eq!(restored.package_identity.as_ref(), Some(&source));
        assert_eq!(restored.tasks, installed.tasks);
        assert!(restored.runtime_swap.is_none());
        assert!(!paths.release.exists());
    }

    #[test]
    fn interrupted_activation_retries_only_its_persisted_source_or_target() {
        for target_selected in [false, true] {
            let root = tempfile::tempdir().expect("isolated interrupted cutover");
            let (paths, staged, store, source) = fixture(root.path(), "0.150.0-alpha.8");
            let target =
                PackageIdentity::read(&staged.path.join("bin/codex")).expect("target identity");
            let swap = RuntimeSwap {
                had_release: false,
                had_current: true,
                previous_current_target: Some(root.path().join("source")),
                had_gateway_env: true,
                source_identity: Some(source.clone()),
                target_identity: Some(target.clone()),
            };
            store
                .update("generation-1", |journal| {
                    journal.runtime_swap = Some(swap);
                    Ok(())
                })
                .expect("durable activation intent");
            std::fs::rename(&paths.current, &paths.previous_current)
                .expect("ownership transferred");
            std::fs::copy(&paths.gateway_env, &paths.previous_gateway_env).expect("env backup");
            std::fs::rename(&paths.staging, &paths.release).expect("target moved");
            if target_selected {
                std::os::unix::fs::symlink(&paths.release, &paths.current)
                    .expect("target selected before crash");
            }
            settle_interrupted_activation(&store, &paths).expect("settle exact activation intent");
            settle_interrupted_activation(&store, &paths).expect("retry is idempotent");
            let settled = store.load().expect("journal").expect("generation");
            assert_eq!(settled.tasks[0].turn_id, "source-turn");
            assert_eq!(settled.tasks[0].status, RecoveryTaskStatus::Suspended);
            if target_selected {
                assert_eq!(settled.phase, RecoveryPhase::RuntimeInstalled);
                assert_eq!(settled.package_identity, Some(target));
                assert!(
                    settled.runtime_swap.is_some(),
                    "candidate owns final activation while predecessor stays unloaded"
                );
            } else {
                assert_eq!(settled.phase, RecoveryPhase::DaemonStopped);
                assert_eq!(settled.package_identity, Some(source.clone()));
                assert!(settled.runtime_swap.is_none());
                source
                    .verify(&paths.current.join("codex"))
                    .expect("source restored");
            }
        }
    }

    #[test]
    fn same_version_replacement_retains_rollback_owner_until_candidate_commit() {
        let root = tempfile::tempdir().expect("isolated same-version cutover");
        let (paths, staged, store, source) = fixture(root.path(), REQUIRED_CODEX_VERSION);
        let installed =
            activate_staged_runtime(&store, "generation-1", &staged).expect("same-version target");
        assert!(installed.runtime_swap.is_some());
        assert_eq!(
            installed
                .runtime_swap
                .as_ref()
                .expect("swap")
                .source_identity
                .as_ref(),
            Some(&source)
        );
        let restored = restore_previous_runtime(&store, "generation-1", &paths)
            .expect("same-version source restored");
        assert_eq!(restored.package_identity, Some(source));
        assert!(restored.runtime_swap.is_none());
    }

    #[tokio::test]
    async fn rollback_captures_new_target_work_before_restoring_source_package() {
        use crate::providers::codex::daemon::CodexAppServer;
        use crate::runtime::transaction::{RecoveryTransaction, RuntimeDestination};
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::Message;
        let root = tempfile::Builder::new()
            .prefix("rc-")
            .tempdir_in("/tmp")
            .expect("short isolated state");
        let (paths, staged, store, source) = fixture(root.path(), "0.150.0-alpha.8");
        let native = root.path().join("c");
        let reply = root.path().join("lifecycle.json");
        let actions = root.path().join("actions");
        std::fs::remove_file(staged.path.join("codex")).expect("replace staged test script");
        write_test_package(
            &staged.path,
            REQUIRED_CODEX_VERSION,
            &format!(
                "printf '%s\\n' \"$3\" >> '{}'\nexec /bin/cat '{}'",
                actions.display(),
                reply.display()
            ),
        );
        let installed =
            activate_staged_runtime(&store, "generation-1", &staged).expect("target installed");
        store
            .update("generation-1", |journal| {
                journal.phase = RecoveryPhase::Completed;
                journal.tasks[0].status = RecoveryTaskStatus::Completed;
                Ok(())
            })
            .expect("source turn already completed on target");
        let codex = paths.current.join("codex");
        let server = CodexAppServer::for_runtime(
            codex.clone(),
            HashMap::from([("CODEX_HOME".into(), native.to_string_lossy().into_owned())]),
        )
        .expect("target owner");
        std::fs::create_dir_all(server.socket_path().parent().expect("socket parent"))
            .expect("socket directory");
        std::fs::create_dir_all(native.join("app-server-daemon")).expect("pid directory");
        std::fs::write(native.join("app-server-daemon/app-server.pid"), serde_json::to_vec(&serde_json::json!({
            "pid": std::process::id(), "processIdentity": crate::test_support::current_process_identity(),
            "executableIdentity": { "digest": *blake3::hash(&std::fs::read(&codex).expect("target bytes")).as_bytes() }
        })).expect("pid JSON")).expect("isolated native identity");
        std::fs::write(&reply, serde_json::to_vec(&serde_json::json!({ "backend": "pid", "pid": std::process::id(), "managedCodexPath": codex, "managedCodexVersion": REQUIRED_CODEX_VERSION, "appServerVersion": REQUIRED_CODEX_VERSION, "socketPath": server.socket_path() })).expect("lifecycle JSON")).expect("lifecycle reply");
        let listener =
            tokio::net::UnixListener::bind(server.socket_path()).expect("isolated native socket");
        let peer = tokio::spawn(async move {
            for connection in 0..2 {
                let (stream, _) = listener.accept().await.expect("connection");
                let mut websocket = tokio_tungstenite::accept_async(stream)
                    .await
                    .expect("WebSocket");
                if connection == 0 {
                    let _ = websocket.next().await;
                    continue;
                }
                while let Some(Ok(Message::Text(raw))) = websocket.next().await {
                    let request: serde_json::Value = serde_json::from_str(&raw).expect("request");
                    let Some(id) = request.get("id") else {
                        continue;
                    };
                    let result = match request["method"].as_str().expect("method") {
                        "initialize" => serde_json::json!({}),
                        "thread/loaded/list" => {
                            serde_json::json!({ "data": ["exact-thread"], "nextCursor": null })
                        }
                        "thread/read" => {
                            serde_json::json!({ "thread": { "id": "exact-thread", "parentThreadId": null, "status": { "type": "active" } } })
                        }
                        "thread/turns/list" => {
                            serde_json::json!({ "data": [{ "id": "new-target-turn", "status": "inProgress" }] })
                        }
                        "thread/restart/suspend" => {
                            assert_eq!(request["params"]["turnId"], "new-target-turn");
                            serde_json::json!({ "outcome": { "status": "suspended", "turnId": "new-target-turn" } })
                        }
                        other => panic!("unexpected method {other}"),
                    };
                    websocket
                        .send(Message::Text(
                            serde_json::json!({ "jsonrpc": "2.0", "id": id, "result": result })
                                .to_string(),
                        ))
                        .await
                        .expect("response");
                }
            }
        });
        RecoveryTransaction::new(&server, &store)
            .restart_transaction(RuntimeDestination::Stopped)
            .await
            .expect("capture and suspend target work");
        peer.await.expect("native peer");
        let captured = store.load().expect("journal").expect("target generation");
        assert_ne!(captured.generation_id, installed.generation_id);
        assert_eq!(captured.tasks[0].turn_id, "new-target-turn");
        assert_eq!(captured.tasks[0].status, RecoveryTaskStatus::Suspended);
        assert_eq!(
            captured
                .runtime_swap
                .as_ref()
                .expect("original rollback owner")
                .source_identity
                .as_ref(),
            Some(&source)
        );
        let restored = restore_previous_runtime(&store, &captured.generation_id, &paths)
            .expect("restore source only after capture");
        assert_eq!(restored.tasks, captured.tasks);
        assert_eq!(restored.generation_id, captured.generation_id);
        source
            .verify(&paths.current.join("codex"))
            .expect("exact original source package");
        let actions = std::fs::read_to_string(actions).expect("lifecycle actions");
        assert!(actions.contains("prepare-restart\n"));
        assert!(actions.ends_with("stop\n"));
    }
}
