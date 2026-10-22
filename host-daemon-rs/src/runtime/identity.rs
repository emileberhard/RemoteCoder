use super::install::package::sha256_file;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PackageIdentity {
    pub(crate) version: String,
    source_commit: String,
    manifest_sha256: String,
    pub(crate) codex_sha256: String,
    code_mode_host_sha256: String,
}

impl PackageIdentity {
    pub(crate) fn read(codex_path: &Path) -> Result<Self> {
        let codex = codex_path
            .canonicalize()
            .context("resolving recovery executable")?;
        let bin = codex
            .parent()
            .context("recovery executable has no parent")?;
        ensure!(
            bin.file_name().is_some_and(|name| name == "bin"),
            "recovery executable is not in a package bin directory"
        );
        let manifest_path = bin
            .parent()
            .context("recovery package has no root")?
            .join("codex-package.json");
        let bytes = std::fs::read(&manifest_path).context("reading recovery package manifest")?;
        let manifest: super::install::package::PackageManifest =
            serde_json::from_slice(&bytes).context("parsing recovery package manifest")?;
        ensure!(
            manifest.layout_version == 1
                && manifest.target == "aarch64-apple-darwin"
                && manifest.variant == "codex"
                && manifest.entrypoint == "bin/codex"
                && manifest.resources_dir == "codex-resources"
                && manifest.path_dir == "codex-path",
            "unsupported recovery package layout"
        );
        for executable in [&codex, &bin.join("codex-code-mode-host")] {
            use std::os::unix::fs::PermissionsExt;
            let metadata = std::fs::metadata(executable)?;
            ensure!(
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0,
                "recovery package executable is not executable"
            );
        }
        let identity = Self {
            version: manifest.version,
            source_commit: manifest.source_commit,
            manifest_sha256: sha256_file(&manifest_path)?,
            codex_sha256: sha256_file(&codex)?,
            code_mode_host_sha256: sha256_file(&bin.join("codex-code-mode-host"))?,
        };
        identity.validate()?;
        for (name, actual) in [
            ("bin/codex", &identity.codex_sha256),
            ("bin/codex-code-mode-host", &identity.code_mode_host_sha256),
        ] {
            ensure!(
                manifest
                    .binaries
                    .get(name)
                    .is_some_and(|binary| &binary.sha256 == actual),
                "recovery package executable {name} differs from its manifest"
            );
        }
        let output = std::process::Command::new(&codex)
            .arg("--version")
            .output()
            .context("probing recovery executable version")?;
        ensure!(
            output.status.success(),
            "recovery executable version probe failed"
        );
        let version = crate::config::parse_codex_version(std::str::from_utf8(&output.stdout)?)?;
        ensure!(
            version == identity.version,
            "recovery executable version differs from its manifest"
        );
        Ok(identity)
    }

    pub(crate) fn validate(&self) -> Result<()> {
        ensure!(
            !self.version.is_empty()
                && self.version.len() <= 128
                && self.source_commit.len() == 40
                && self
                    .source_commit
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit()),
            "invalid recovery package version or source commit"
        );
        for hash in [
            &self.manifest_sha256,
            &self.codex_sha256,
            &self.code_mode_host_sha256,
        ] {
            ensure!(
                hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()),
                "invalid recovery package digest"
            );
        }
        Ok(())
    }

    pub(crate) fn verify(&self, codex_path: &Path) -> Result<()> {
        ensure!(
            Self::read(codex_path)? == *self,
            "recovery package identity changed"
        );
        Ok(())
    }
}

pub(crate) fn verify_recovery_package(codex_path: &Path) -> Result<PackageIdentity> {
    let identity = PackageIdentity::read(codex_path)?;
    let store =
        super::recovery::RecoveryStore::new(super::recovery::RecoveryStore::default_path()?);
    let journal = store
        .load()?
        .context("recovery-only gateway has no persisted generation")?;
    ensure!(
        journal.package_identity.as_ref() == Some(&identity),
        "recovery-only gateway package is not bound to its persisted generation"
    );
    Ok(identity)
}

pub(super) fn release_source_journal_identities(
    store: &super::recovery::RecoveryStore,
    _home: &Path,
) -> Result<()> {
    let _control_owner = super::ControlOwnerLease::acquire(store)?;
    let Some(journal) = store.load()? else {
        return Ok(());
    };
    ensure!(
        journal.phase == super::recovery::RecoveryPhase::Completed
            && journal.runtime_swap.is_none(),
        "source recovery is not complete"
    );
    store.update(&journal.generation_id, |journal| {
        journal.package_identity = None;
        Ok(())
    })?;
    Ok(())
}

#[cfg(test)]
pub(super) fn write_test_package(root: &Path, version: &str, body: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(root.join("bin")).expect("package directory");
    let codex = root.join("bin/codex");
    std::fs::write(&codex, format!("#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli {version}'; exit 0; fi\n{body}\n")).expect("executable");
    let host = root.join("bin/codex-code-mode-host");
    std::fs::write(&host, "#!/bin/sh\nexit 0\n").expect("code mode host");
    for executable in [&codex, &host] {
        std::fs::set_permissions(executable, std::fs::Permissions::from_mode(0o755))
            .expect("executable permissions");
    }
    std::fs::write(root.join("codex-package.json"), serde_json::to_vec(&serde_json::json!({
        "layoutVersion": 1, "version": version, "sourceCommit": "b".repeat(40), "target": "aarch64-apple-darwin", "variant": "codex", "entrypoint": "bin/codex", "resourcesDir": "codex-resources", "pathDir": "codex-path",
        "binaries": { "bin/codex": { "sha256": sha256_file(&codex).expect("codex hash") }, "bin/codex-code-mode-host": { "sha256": sha256_file(&host).expect("host hash") } }
    })).expect("manifest JSON")).expect("manifest");
    std::os::unix::fs::symlink("bin/codex", root.join("codex")).expect("root executable");
    codex
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_package_rejects_missing_manifest_version_and_hash_before_lifecycle() {
        let directory = tempfile::tempdir().expect("isolated source");
        let root = directory.path().join("package");
        let lifecycle = directory.path().join("actions");
        let codex = write_test_package(
            &root,
            "0.150.0-alpha.8",
            &format!("echo lifecycle >> '{}'", lifecycle.display()),
        );
        let identity = PackageIdentity::read(&codex).expect("verified source");
        assert_eq!(identity.version, "0.150.0-alpha.8");
        let manifest_path = root.join("codex-package.json");
        let original = std::fs::read(&manifest_path).expect("manifest");
        let mut manifest: serde_json::Value = serde_json::from_slice(&original).expect("JSON");
        manifest["version"] = serde_json::json!("0.151.0-alpha.7.1");
        std::fs::write(&manifest_path, serde_json::to_vec(&manifest).expect("JSON"))
            .expect("changed version");
        assert!(
            PackageIdentity::read(&codex)
                .expect_err("different executable version")
                .to_string()
                .contains("version differs")
        );
        std::fs::write(&manifest_path, &original).expect("restore manifest");
        std::fs::write(root.join("bin/codex-code-mode-host"), "changed executable")
            .expect("changed host");
        assert!(
            identity
                .verify(&codex)
                .expect_err("different host digest")
                .to_string()
                .contains("differs from its manifest")
        );
        std::fs::remove_file(manifest_path).expect("missing manifest");
        assert!(PackageIdentity::read(&codex).is_err());
        assert!(
            !lifecycle.exists(),
            "no app-server lifecycle action is allowed during identity checks"
        );
    }
}
