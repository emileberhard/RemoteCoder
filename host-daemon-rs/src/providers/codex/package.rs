use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};

pub(crate) fn prepare(codex_home: &Path, approved: &Path) -> Result<()> {
    let approved_root =
        std::fs::canonicalize(approved).context("Resolving the approved shared Codex package")?;
    ensure!(
        approved_root.join("bin/codex").is_file()
            && approved_root.join("codex-package.json").is_file(),
        "The approved Codex runtime must be a complete package"
    );
    let current = selected_root(codex_home)?.join("current");
    if !entry_exists(&current)? {
        let selected = current.parent().context("Codex package has no parent")?;
        std::fs::create_dir_all(selected)?;
        for directory in [codex_home.join("packages"), selected.to_path_buf()] {
            ensure!(
                std::fs::symlink_metadata(&directory)?.file_type().is_dir(),
                "Codex package directory has another owner: {}",
                directory.display()
            );
            std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
        }
        match std::os::unix::fs::symlink(approved, &current) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error).context("Linking the approved Codex package"),
        }
    }
    ensure!(
        std::fs::canonicalize(&current)? == approved_root,
        "Selected Codex package {} differs from the approved shared package; preserve its owner and repair through a runtime cutover",
        current.display()
    );
    Ok(())
}

fn selected_root(codex_home: &Path) -> Result<PathBuf> {
    let dedicated = codex_home.join("packages/app-server-daemon");
    if entry_exists(&dedicated.join("current"))? {
        return Ok(dedicated);
    }
    let state = codex_home.join("app-server-daemon");
    for (package, artifacts) in [
        (
            "app-server-daemon",
            [
                "daemon.pid",
                "daemon.stderr.log",
                "daemon-updater.pid",
                "daemon-updater.stderr.log",
            ],
        ),
        (
            "standalone",
            [
                "app-server.pid",
                "app-server.stderr.log",
                "app-server-updater.pid",
                "app-server-updater.stderr.log",
            ],
        ),
    ] {
        for artifact in artifacts {
            if entry_exists(&state.join(artifact))? {
                return Ok(codex_home.join("packages").join(package));
            }
        }
    }
    Ok(dedicated)
}

fn entry_exists(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error)
            .with_context(|| format!("Reading Codex installation path {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_homes_follow_the_shared_package_and_legacy_owners_keep_their_namespace() {
        let directory = tempfile::tempdir().expect("package test");
        let approved = directory.path().join("approved/current");
        for name in ["first", "second"] {
            let root = directory.path().join(name);
            std::fs::create_dir_all(root.join("bin")).expect("package bin");
            std::fs::write(root.join("bin/codex"), name).expect("binary");
            std::fs::write(root.join("codex-package.json"), "{}").expect("manifest");
        }
        std::fs::create_dir_all(approved.parent().expect("approved parent")).expect("parent");
        std::os::unix::fs::symlink(directory.path().join("first"), &approved).expect("shared link");
        let fresh = directory.path().join("fresh");
        prepare(&fresh, &approved).expect("fresh package");
        let fresh_current = fresh.join("packages/app-server-daemon/current");
        assert_eq!(
            std::fs::read_link(&fresh_current).expect("fresh link"),
            approved
        );
        assert!(!fresh.join("packages/standalone/current").exists());
        assert_eq!(
            std::fs::metadata(fresh.join("packages/app-server-daemon"))
                .expect("private package directory")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let legacy = directory.path().join("legacy");
        std::fs::create_dir_all(legacy.join("app-server-daemon")).expect("legacy state");
        std::fs::write(
            legacy.join("app-server-daemon/app-server.stderr.log"),
            "prior launch",
        )
        .expect("legacy launch artifact");
        prepare(&legacy, &approved).expect("legacy package");
        let legacy_current = legacy.join("packages/standalone/current");
        assert_eq!(
            std::fs::read_link(&legacy_current).expect("legacy link"),
            approved
        );
        assert!(!legacy.join("packages/app-server-daemon/current").exists());
        let next = approved.with_extension("next");
        std::os::unix::fs::symlink(directory.path().join("second"), &next).expect("next package");
        std::fs::rename(next, &approved).expect("atomic package switch");
        for current in [fresh_current, legacy_current] {
            assert_eq!(
                std::fs::read_to_string(current.join("bin/codex")).expect("shared binary"),
                "second"
            );
        }
        prepare(&fresh, &approved).expect("unchanged gateway restart");
        prepare(&legacy, &approved).expect("legacy gateway restart");
    }

    #[test]
    fn another_selected_package_is_preserved_and_rejected() {
        let directory = tempfile::tempdir().expect("package test");
        let home = directory.path().join("home");
        let selected = home.join("packages/app-server-daemon/current");
        let approved = directory.path().join("approved");
        std::fs::create_dir_all(approved.join("bin")).expect("approved bin");
        std::fs::write(approved.join("bin/codex"), "approved").expect("binary");
        std::fs::write(approved.join("codex-package.json"), "{}").expect("manifest");
        std::fs::create_dir_all(&selected).expect("existing package");
        std::fs::write(selected.join("keep"), "existing owner").expect("existing content");
        assert!(prepare(&home, &approved).is_err());
        assert_eq!(
            std::fs::read_to_string(selected.join("keep")).expect("preserved package"),
            "existing owner"
        );
    }
}
