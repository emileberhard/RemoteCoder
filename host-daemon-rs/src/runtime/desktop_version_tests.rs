use super::desktop::{read_bundled_codex_version, record_bundled_codex_version};
use crate::observability::desktop::DesktopJournal;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

fn bundled_executable(application: &Path, relative: &str, body: &str) -> PathBuf {
    let executable = application.join(relative);
    std::fs::create_dir_all(executable.parent().expect("bundle directory")).expect("bundle layout");
    std::fs::write(
        &executable,
        format!(
            "#!/bin/sh\nprintf called >> '{}'/probes\n{body}\n",
            application.display()
        ),
    )
    .expect("bundled executable");
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755))
        .expect("executable permission");
    executable
}

#[test]
fn observed_official_bundle_layouts_require_the_selected_runtime_version() {
    for (relative, version, other) in [
        (
            "Contents/Resources/codex",
            "0.155.0-alpha.16",
            "0.158.0-alpha.2.1",
        ),
        (
            "Contents/Resources/codex-cli/bin/codex",
            "0.158.0-alpha.2.1",
            "0.155.0-alpha.16",
        ),
    ] {
        let directory = tempfile::tempdir().expect("isolated official bundle");
        bundled_executable(
            directory.path(),
            relative,
            &format!("echo 'codex-cli {version}'"),
        );
        let journal = DesktopJournal::in_dir(directory.path(), "launch", "install");
        record_bundled_codex_version(
            &journal,
            version,
            read_bundled_codex_version(directory.path()),
        )
        .expect("matched source or target bundle");
        assert!(
            journal
                .records()
                .iter()
                .any(|record| record["event"] == "desktop/version"
                    && record["ok"] == true
                    && record["bundledCodexVersion"] == version)
        );
        record_bundled_codex_version(
            &journal,
            other,
            read_bundled_codex_version(directory.path()),
        )
        .expect_err("different runtime remains closed");
        let records = journal.records();
        let decision = records
            .iter()
            .find(|record| record["event"] == "desktop/decision")
            .expect("pairing decision");
        assert_eq!(decision["reason"], "incompatible-version");
        assert_eq!(decision["action"], "abort");
        assert_eq!(decision["requiredCodexVersion"], other);
    }
}

#[test]
fn missing_ambiguous_and_broken_bundle_probes_are_observation_failures() {
    for case in [
        "missing",
        "ambiguous",
        "ambiguous-broken",
        "dangling-legacy",
        "dangling-packaged",
        "unreadable",
        "failed",
        "malformed",
    ] {
        let directory = tempfile::tempdir().expect("isolated official bundle");
        match case {
            "missing" => {}
            "ambiguous" => {
                for relative in [
                    "Contents/Resources/codex",
                    "Contents/Resources/codex-cli/bin/codex",
                ] {
                    bundled_executable(
                        directory.path(),
                        relative,
                        "echo 'codex-cli 0.155.0-alpha.16'",
                    );
                }
            }
            "ambiguous-broken" => {
                let executable = directory.path().join("Contents/Resources/codex");
                std::fs::create_dir_all(executable.parent().expect("bundle directory"))
                    .expect("bundle layout");
                std::os::unix::fs::symlink("missing", executable)
                    .expect("present broken legacy path");
                bundled_executable(
                    directory.path(),
                    "Contents/Resources/codex-cli/bin/codex",
                    "echo 'codex-cli 0.155.0-alpha.16'",
                );
            }
            "dangling-legacy" | "dangling-packaged" => {
                let relative = if case == "dangling-legacy" {
                    "Contents/Resources/codex"
                } else {
                    "Contents/Resources/codex-cli/bin/codex"
                };
                let executable = directory.path().join(relative);
                std::fs::create_dir_all(executable.parent().expect("bundle directory"))
                    .expect("bundle layout");
                std::os::unix::fs::symlink("missing", executable)
                    .expect("broken selected executable");
            }
            "unreadable" => {
                let executable = bundled_executable(
                    directory.path(),
                    "Contents/Resources/codex",
                    "echo 'codex-cli 0.155.0-alpha.16'",
                );
                std::fs::set_permissions(executable, std::fs::Permissions::from_mode(0o000))
                    .expect("unreadable selected executable");
            }
            "failed" => {
                bundled_executable(
                    directory.path(),
                    "Contents/Resources/codex",
                    "echo 'codex-cli 0.155.0-alpha.16'; exit 1",
                );
            }
            "malformed" => {
                bundled_executable(
                    directory.path(),
                    "Contents/Resources/codex-cli/bin/codex",
                    "echo 'not-codex 0.155.0-alpha.16'",
                );
            }
            _ => unreachable!(),
        }
        let journal = DesktopJournal::in_dir(directory.path(), "launch", "install");
        let error = record_bundled_codex_version(
            &journal,
            "0.155.0-alpha.16",
            read_bundled_codex_version(directory.path()),
        )
        .expect_err(case);
        if matches!(case, "missing" | "ambiguous" | "ambiguous-broken") {
            let failure = if case == "missing" {
                "missing"
            } else {
                "ambiguous"
            };
            assert!(format!("{error:#}").contains(failure));
            assert!(
                !directory.path().join("probes").exists(),
                "{case} executed a candidate"
            );
        }
        let records = journal.records();
        let decision = records
            .iter()
            .find(|record| record["event"] == "desktop/decision")
            .expect("observation decision");
        assert_eq!(decision["reason"], "observation-failed", "{case}");
        assert_eq!(decision["action"], "abort", "{case}");
    }
}
