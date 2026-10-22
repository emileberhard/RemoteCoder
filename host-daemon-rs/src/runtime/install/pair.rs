use super::bundle::{BINARY, GatewayArtifact};
use crate::config::HostPaths;
use crate::runtime::install::package::sha256_file;
use crate::storage::private_state;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Identity {
    gateway_hash: String,
    config_hash: Option<String>,
    worker_hash: Option<String>,
}

pub(crate) struct Pair {
    directory: PathBuf,
    source: Option<PathBuf>,
    candidate: PathBuf,
}

pub(crate) fn directory(paths: &HostPaths) -> PathBuf {
    paths.home().join("localbin/remote-coder-gateway")
}

pub(crate) fn selected_config(paths: &HostPaths) -> Result<PathBuf> {
    let root = directory(paths);
    match selected(&root, "current")? {
        Some(version) => Ok(version.join("call-delivery.json")),
        None => Ok(paths.state("call-delivery.json")),
    }
}

pub(crate) fn selected_worker(paths: &HostPaths) -> Result<Option<String>> {
    let root = directory(paths);
    let Some(version) = selected(&root, "current")? else {
        let binary = root.join(BINARY);
        if !binary.exists() {
            return Ok(None);
        }
        let output = std::process::Command::new(binary)
            .arg("--version")
            .output()?;
        ensure!(
            output.status.success() && output.stdout.len() <= 4096,
            "Source gateway identity is unavailable"
        );
        let value: serde_json::Value = serde_json::from_slice(&output.stdout)?;
        let worker = value
            .get("workerHash")
            .map(|value| value.as_str().context("Invalid source worker identity"))
            .transpose()?;
        ensure!(
            worker.is_none_or(
                |hash| hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
            ),
            "Invalid source worker hash"
        );
        return Ok(worker.map(str::to_owned));
    };
    Ok(identity(&version)?.worker_hash)
}

pub(crate) fn require_current_binary(paths: &HostPaths) -> Result<()> {
    ensure!(
        std::env::current_exe()?.canonicalize()? == directory(paths).join(BINARY).canonicalize()?,
        "Call installation must use the currently installed gateway binary"
    );
    Ok(())
}

fn identity(version: &Path) -> Result<Identity> {
    let bytes = private_state::read_bounded(&version.join("pair.json"), 4096)
        .map_err(|error| anyhow::anyhow!("Cannot read gateway pair identity: {error:?}"))?
        .context("Gateway pair identity is missing")?;
    Ok(serde_json::from_slice(&bytes)?)
}

pub(crate) fn startup_config(paths: &HostPaths) -> Result<PathBuf> {
    config_for_executable(paths, &std::env::current_exe()?)
}

fn config_for_executable(paths: &HostPaths, executable: &Path) -> Result<PathBuf> {
    let artifact = GatewayArtifact::load(executable)?;
    let owner = artifact.version_directory()?;
    if owner.join("pair.json").exists() {
        Ok(owner.join("call-delivery.json"))
    } else {
        selected_config(paths)
    }
}

fn prune_versions(root: &Path, keep: &[PathBuf]) -> Result<()> {
    let versions = root.join("versions");
    if !versions.exists() {
        return Ok(());
    }
    for entry in std::fs::read_dir(versions)? {
        let path = entry?.path();
        if !keep.contains(&path) {
            let name = path
                .file_name()
                .context("Version has no name")?
                .to_string_lossy();
            let named = name.len() == 64 && name.bytes().all(|byte| byte.is_ascii_hexdigit());
            let staged = name
                .strip_prefix('.')
                .is_some_and(crate::ids::is_session_uuid);
            ensure!(
                (named || staged) && !path.is_symlink() && path.is_dir(),
                "Unknown gateway version entry"
            );
            std::fs::remove_dir_all(path)?;
        }
    }
    File::open(root.join("versions"))?.sync_all()?;
    Ok(())
}

fn selected(root: &Path, name: &str) -> Result<Option<PathBuf>> {
    let target = match std::fs::read_link(root.join(name)) {
        Ok(target) => target,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let components = target.components().collect::<Vec<_>>();
    ensure!(
        components.len() == 2 && target.parent() == Some(Path::new("versions")),
        "Invalid gateway version pointer"
    );
    let hash = target
        .file_name()
        .context("Gateway version has no name")?
        .to_string_lossy();
    ensure!(
        hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "Invalid gateway version hash"
    );
    let version = root.join(target);
    ensure!(
        version.is_dir() && !version.is_symlink(),
        "Gateway version is unavailable"
    );
    Ok(Some(version))
}

struct PointerSwap {
    temporary: PathBuf,
    destination: PathBuf,
    root: PathBuf,
}

impl PointerSwap {
    fn prepare(root: &Path, name: &str, version: &Path) -> Result<Self> {
        let relative = version.strip_prefix(root)?;
        let temporary = root.join(format!(".{name}.{}", crate::ids::new_session_uuid()));
        symlink(relative, &temporary)?;
        Ok(Self {
            temporary,
            destination: root.join(name),
            root: root.to_owned(),
        })
    }

    fn commit(self) -> Result<()> {
        std::fs::rename(&self.temporary, &self.destination)?;
        File::open(&self.root)?.sync_all()?;
        Ok(())
    }
}

impl Drop for PointerSwap {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.temporary);
    }
}

fn select(root: &Path, name: &str, version: &Path) -> Result<()> {
    PointerSwap::prepare(root, name, version)?.commit()
}

fn version(
    root: &Path,
    binary: &Path,
    config: Option<&[u8]>,
    worker: Option<String>,
) -> Result<PathBuf> {
    let artifact = GatewayArtifact::load(binary)?;
    let binary = artifact.binary();
    ensure!(
        std::fs::metadata(&binary)?.len() <= 256 * 1024 * 1024,
        "Gateway binary exceeds installation capacity"
    );
    ensure!(
        config.is_none_or(|bytes| bytes.len() <= 65536),
        "Gateway call configuration exceeds installation capacity"
    );
    let gateway_hash = sha256_file(&binary)?;
    let config_hash = config.map(|bytes| format!("{:x}", Sha256::digest(bytes)));
    let metadata = Identity {
        gateway_hash,
        config_hash,
        worker_hash: worker,
    };
    let bytes = serde_json::to_vec(&metadata)?;
    let hash = format!("{:x}", Sha256::digest(&bytes));
    let destination = root.join("versions").join(hash);
    if destination.exists() {
        ensure!(
            std::fs::read(destination.join("pair.json"))? == bytes,
            "Gateway pair identity changed"
        );
        ensure!(
            sha256_file(&destination.join(BINARY))? == metadata.gateway_hash,
            "Immutable gateway binary changed"
        );
        ensure!(
            artifact.matches(&destination)?,
            "Immutable gateway artifact changed"
        );
        ensure!(
            read_config(&destination)? == config.map(<[u8]>::to_vec),
            "Immutable gateway configuration changed"
        );
        return Ok(destination);
    }
    private_state::ensure_private_directory(&root.join("versions"))?;
    let staged = root
        .join("versions")
        .join(format!(".{}", crate::ids::new_session_uuid()));
    private_state::ensure_private_directory(&staged)?;
    let result = (|| -> Result<()> {
        artifact.copy_to(&staged)?;
        ensure!(
            sha256_file(&staged.join(BINARY))? == metadata.gateway_hash,
            "Gateway candidate changed during staging"
        );
        if let Some(config) = config {
            private_state::replace(&staged.join("call-delivery.json"), config)?;
        }
        private_state::replace(&staged.join("pair.json"), &bytes)?;
        std::fs::rename(&staged, &destination)?;
        File::open(root.join("versions"))?.sync_all()?;
        Ok(())
    })();
    if result.is_err() && staged.exists() {
        std::fs::remove_dir_all(staged)?;
    }
    result?;
    Ok(destination)
}

fn read_config(version: &Path) -> Result<Option<Vec<u8>>> {
    private_state::read_bounded(&version.join("call-delivery.json"), 65536)
        .map_err(|error| anyhow::anyhow!("Cannot read gateway pair configuration: {error:?}"))
}

impl Pair {
    pub(super) fn prepare(paths: &HostPaths, binary: &Path, config: Option<&[u8]>) -> Result<Self> {
        let root = directory(paths);
        private_state::ensure_private_directory(&root)?;
        for entry in std::fs::read_dir(&root)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            for prefix in [".current.", ".previous.", ".binary."] {
                if name
                    .strip_prefix(prefix)
                    .is_some_and(crate::ids::is_session_uuid)
                {
                    ensure!(
                        entry.file_type()?.is_symlink(),
                        "Unknown gateway pointer staging entry"
                    );
                    std::fs::remove_file(entry.path())?;
                }
            }
        }
        let keep = [selected(&root, "current")?, selected(&root, "previous")?]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        prune_versions(&root, &keep)?;
        let source = match selected(&root, "current")? {
            Some(source) => Some(source),
            None if root.join(BINARY).exists() => {
                let legacy = private_state::read_bounded(&paths.state("call-delivery.json"), 65536)
                    .map_err(|error| {
                        anyhow::anyhow!("Cannot read source call configuration: {error:?}")
                    })?;
                let worker = selected_worker(paths)?;
                Some(version(
                    &root,
                    &root.join(BINARY),
                    legacy.as_deref(),
                    worker,
                )?)
            }
            None => None,
        };
        let candidate = version(
            &root,
            binary,
            config,
            Some(crate::build_identity::IDENTITY.worker_hash.to_owned()),
        )?;
        Ok(Self {
            directory: root,
            source,
            candidate,
        })
    }

    fn prepare_activation(&self) -> Result<PointerSwap> {
        if let Some(source) = &self.source {
            if selected(&self.directory, "current")?.is_none() {
                select(&self.directory, "current", source)?;
            }
            select(&self.directory, "previous", source)?;
        }
        let alias = self
            .directory
            .join(format!(".binary.{}", crate::ids::new_session_uuid()));
        symlink(format!("current/{BINARY}"), &alias)?;
        std::fs::rename(alias, self.directory.join(BINARY))?;
        File::open(&self.directory)?.sync_all()?;
        PointerSwap::prepare(&self.directory, "current", &self.candidate)
    }

    pub(super) fn activate(&self) -> Result<()> {
        self.prepare_activation()?.commit()
    }

    pub(super) fn restore(&self) -> Result<()> {
        match &self.source {
            Some(source) => {
                select(&self.directory, "previous", &self.candidate)?;
                select(&self.directory, "current", source)
            }
            None => {
                std::fs::remove_file(self.directory.join(BINARY))?;
                std::fs::remove_file(self.directory.join("current"))?;
                File::open(&self.directory)?.sync_all()?;
                Ok(())
            }
        }
    }

    pub(super) fn prune(&self) -> Result<()> {
        let keep = [
            selected(&self.directory, "current")?,
            selected(&self.directory, "previous")?,
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
        prune_versions(&self.directory, &keep)
    }
}

pub(crate) fn configure(paths: &HostPaths, config: &[u8]) -> Result<PathBuf> {
    let config = crate::gateway::calls::CallDeliveryConfig::parse_for_install(config)?;
    config.require_worker_hash()?;
    let bytes = serde_json::to_vec_pretty(&config)?;
    let pair = Pair::prepare(paths, &std::env::current_exe()?, Some(&bytes))?;
    pair.activate()?;
    pair.prune()?;
    Ok(pair.candidate.join("call-delivery.json"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Read};
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Child, Command, Stdio};

    struct Owner(Child);
    impl Drop for Owner {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn executable(path: &Path, value: &str) {
        std::fs::write(path, format!("#!/bin/sh\ndirectory=\"$(dirname \"$0\")\"\ncase \"$directory\" in */Contents/MacOS) directory=\"$directory/../../..\";; esac\n[ \"$(cat \"$directory/call-delivery.json\")\" = '{value}' ] || exit 42\nprintf '{value}\\n'\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn bundle(path: &Path, value: &str) -> PathBuf {
        let bundle = path.join(super::super::bundle::NAME);
        let binary = super::super::bundle::executable(&bundle);
        std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
        executable(&binary, value);
        std::fs::write(bundle.join("Contents/Info.plist"), b"bundle metadata").unwrap();
        std::fs::create_dir(bundle.join("Contents/_CodeSignature")).unwrap();
        std::fs::write(
            bundle.join("Contents/_CodeSignature/CodeResources"),
            b"resource seal",
        )
        .unwrap();
        bundle
    }

    #[test]
    fn bundle_pair_keeps_all_signed_files_and_restores_a_flat_source() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let source = home.path().join("source");
        executable(&source, "source");
        Pair::prepare(&paths, &source, Some(b"source"))
            .unwrap()
            .activate()
            .unwrap();
        let candidate = bundle(home.path(), "candidate");
        let pair = Pair::prepare(&paths, &candidate, Some(b"candidate")).unwrap();
        let version = &pair.candidate;
        assert_eq!(
            std::fs::read_link(version.join(BINARY)).unwrap(),
            Path::new("RemoteCoderGateway.app/Contents/MacOS/remote-coder-codex-gateway")
        );
        for member in [
            "Contents/Info.plist",
            "Contents/_CodeSignature/CodeResources",
            "Contents/MacOS/remote-coder-codex-gateway",
        ] {
            assert_eq!(
                std::fs::read(version.join("RemoteCoderGateway.app").join(member)).unwrap(),
                std::fs::read(candidate.join(member)).unwrap()
            );
        }
        let metadata: serde_json::Value =
            serde_json::from_slice(&std::fs::read(version.join("pair.json")).unwrap()).unwrap();
        assert_eq!(
            metadata["gatewayHash"],
            format!(
                "{:x}",
                Sha256::digest(
                    std::fs::read(candidate.join("Contents/MacOS/remote-coder-codex-gateway"))
                        .unwrap()
                )
            )
        );
        assert_eq!(
            metadata["configHash"],
            format!("{:x}", Sha256::digest(b"candidate"))
        );
        assert_eq!(
            metadata["workerHash"],
            crate::build_identity::IDENTITY.worker_hash
        );
        pair.activate().unwrap();
        let alias = directory(&paths).join(BINARY);
        let running = alias.canonicalize().unwrap();
        assert_eq!(
            config_for_executable(&paths, &running).unwrap(),
            version.join("call-delivery.json").canonicalize().unwrap()
        );
        assert_eq!(
            Command::new(&running).output().unwrap().stdout,
            b"candidate\n"
        );
        assert!(Pair::prepare(&paths, &running, Some(b"candidate")).is_ok());
        pair.restore().unwrap();
        assert!(
            !alias
                .canonicalize()
                .unwrap()
                .parent()
                .unwrap()
                .join("Contents")
                .exists()
        );
        assert_eq!(
            config_for_executable(&paths, &alias).unwrap(),
            pair.source
                .as_ref()
                .unwrap()
                .join("call-delivery.json")
                .canonicalize()
                .unwrap()
        );
        assert_eq!(
            Command::new(alias.canonicalize().unwrap())
                .output()
                .unwrap()
                .stdout,
            b"source\n"
        );
        assert_eq!(
            selected(&directory(&paths), "previous").unwrap(),
            Some(version.clone())
        );
        pair.prune().unwrap();
        assert!(version.is_dir());
    }

    #[test]
    fn immutable_bundle_reuse_rejects_changed_seal_metadata_and_extra_files() {
        for member in [
            "Contents/Info.plist",
            "Contents/_CodeSignature/CodeResources",
            "Contents/extra",
        ] {
            let home = tempfile::tempdir().unwrap();
            let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
            let candidate = bundle(home.path(), "candidate");
            let pair = Pair::prepare(&paths, &candidate, Some(b"candidate")).unwrap();
            pair.activate().unwrap();
            std::fs::write(
                pair.candidate.join("RemoteCoderGateway.app").join(member),
                b"changed",
            )
            .unwrap();
            let error = Pair::prepare(&paths, &candidate, Some(b"candidate"))
                .err()
                .unwrap();
            assert!(
                error
                    .to_string()
                    .contains("Immutable gateway artifact changed"),
                "{error:#}"
            );
        }
    }

    #[test]
    fn legacy_pair_keeps_the_binary_worker_identity_without_call_configuration() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let root = directory(&paths);
        std::fs::create_dir_all(&root).unwrap();
        let hash = "a".repeat(64);
        let source = root.join(BINARY);
        std::fs::write(
            &source,
            format!("#!/bin/sh\nprintf '{{\"workerHash\":\"{hash}\"}}\\n'\n"),
        )
        .unwrap();
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o755)).unwrap();
        let pair = Pair::prepare(&paths, &source, None).unwrap();
        assert_eq!(
            identity(pair.source.as_ref().unwrap()).unwrap().worker_hash,
            Some(hash)
        );
    }

    #[test]
    fn pair_owner_child() {
        let Ok(home) = std::env::var("RC_PAIR_FIXTURE_HOME") else {
            return;
        };
        let paths = HostPaths::from_home(PathBuf::from(home)).unwrap();
        let phase = std::env::var("RC_PAIR_FIXTURE_PHASE").unwrap();
        let pair = Pair::prepare(
            &paths,
            &paths.home().join(super::super::bundle::NAME),
            Some(b"candidate"),
        )
        .unwrap();
        let swap = if phase.starts_with("rollback") {
            pair.activate().unwrap();
            select(&pair.directory, "previous", &pair.candidate).unwrap();
            PointerSwap::prepare(&pair.directory, "current", pair.source.as_ref().unwrap()).unwrap()
        } else {
            pair.prepare_activation().unwrap()
        };
        if phase.ends_with("after") {
            swap.commit().unwrap();
        }
        println!("PAIR_READY");
        let mut signal = [0_u8];
        std::io::stdin().read_exact(&mut signal).unwrap();
    }

    #[test]
    fn killed_pair_owner_restart_observes_one_matching_binary_and_config() {
        for (phase, expected) in [
            ("before", "source"),
            ("after", "candidate"),
            ("rollback-before", "candidate"),
            ("rollback-after", "source"),
        ] {
            let home = tempfile::tempdir().unwrap();
            let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
            let source = home.path().join("source");
            executable(&source, "source");
            Pair::prepare(&paths, &source, Some(b"source"))
                .unwrap()
                .activate()
                .unwrap();
            bundle(home.path(), "candidate");
            let mut owner = Owner(
                Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--exact",
                        "runtime::install::pair::tests::pair_owner_child",
                        "--nocapture",
                    ])
                    .env("RC_PAIR_FIXTURE_HOME", home.path())
                    .env("RC_PAIR_FIXTURE_PHASE", phase)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .spawn()
                    .unwrap(),
            );
            let output = owner.0.stdout.take().unwrap();
            let (sender, receiver) = std::sync::mpsc::sync_channel(1);
            let reader = std::thread::spawn(move || {
                for line in std::io::BufReader::new(output).lines() {
                    if line.unwrap() == "PAIR_READY" {
                        sender.send(()).unwrap();
                        return;
                    }
                }
            });
            receiver
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            owner.0.kill().unwrap();
            assert!(!owner.0.wait().unwrap().success());
            reader.join().unwrap();
            let resolved = std::fs::canonicalize(directory(&paths).join(BINARY)).unwrap();
            let restarted = Command::new(resolved).output().unwrap();
            assert!(restarted.status.success(), "{phase}: {restarted:?}");
            assert_eq!(
                String::from_utf8(restarted.stdout).unwrap().trim(),
                expected,
                "{phase}"
            );
        }
    }
}
