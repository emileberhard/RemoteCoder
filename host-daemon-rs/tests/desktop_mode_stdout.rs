use std::ffi::OsStr;
use std::process::Command;

#[test]
fn runtime_desktop_mode_prints_only_the_mode_on_stdout() {
    let home = tempfile::tempdir().unwrap();
    let env_file = home.path().join("codex-gateway.env");
    std::fs::write(&env_file, "RC_CODEX_GATEWAY_LOG=info\n").unwrap();

    for env_args in [vec![OsStr::new("--env-file"), env_file.as_os_str()], vec![]] {
        let output = Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
            .env("HOME", home.path())
            .env_remove("RUST_LOG")
            .env_remove("RC_CODEX_GATEWAY_LOG")
            .args(&env_args)
            .args(["runtime", "desktop", "mode"])
            .output()
            .unwrap();

        assert!(output.status.success(), "{output:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(
            stdout == "shared\n" || stdout == "disabled\n",
            "stdout must be exactly the mode, got {stdout:?}"
        );
    }
}
