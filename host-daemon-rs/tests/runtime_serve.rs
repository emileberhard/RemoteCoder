use std::process::Command;

#[test]
fn runtime_serve_rejects_gateway_ingress_configuration_before_startup() {
    let home = tempfile::tempdir().unwrap();
    let env_file = home.path().join("runtime.env");
    for key in [
        "RC_CODEX_GATEWAY_BIND_HOST",
        "RC_CODEX_GATEWAY_PORT",
        "RC_CODEX_GATEWAY_LAN_PORT",
        "RC_CODEX_GATEWAY_LAN_BIND_ADDRESS",
        "RC_CODEX_GATEWAY_LAN_HOST",
        "RC_CODEX_GATEWAY_AUTH_TOKEN",
        "RC_CODEX_GATEWAY_CLUSTER_ROUTES",
        "RC_AGENT_JOB_SOCKET",
    ] {
        std::fs::write(&env_file, format!("{key}=\n")).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
            .env_clear()
            .env("HOME", home.path())
            .args(["--env-file"])
            .arg(&env_file)
            .args(["runtime", "serve"])
            .output()
            .unwrap();
        assert!(!output.status.success(), "{key}: {output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains(&format!("runtime serve does not accept {key}")),
            "{key}: {output:?}"
        );
    }
}
