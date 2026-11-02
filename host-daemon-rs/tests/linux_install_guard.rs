#![cfg(target_os = "linux")]

#[test]
fn macos_pair_operations_refuse_before_creating_state() {
    for arguments in [
        vec!["runtime", "install-gateway", "--stage-id", "1"],
        vec!["runtime", "prepare-gateway-stage", "--stage-id", "1"],
        vec!["runtime", "configure-call-delivery"],
        vec!["runtime", "desktop", "mode"],
    ] {
        let home = tempfile::tempdir().unwrap();
        let result = std::process::Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
            .args(arguments)
            .env("HOME", home.path())
            .output()
            .unwrap();
        assert!(!result.status.success());
        assert!(String::from_utf8_lossy(&result.stderr).contains("macOS-only"));
        assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
    }
}
