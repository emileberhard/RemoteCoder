use std::os::unix::fs::PermissionsExt;
use std::process::Command;

use serde_json::json;
use sha2::{Digest, Sha256};

#[test]
fn version_prints_only_build_identity_without_loading_settings() {
    let directory = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
        .arg("--version")
        .arg("--env-file")
        .arg(directory.path().join("missing.env"))
        .current_dir(directory.path())
        .env("HOME", directory.path())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 1);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&stdout).unwrap(),
        json!({
            "version": option_env!("RC_RELEASE_VERSION").unwrap_or("dev"),
            "commit": option_env!("RC_SOURCE_COMMIT"),
            "modified": option_env!("RC_SOURCE_MODIFIED").map(|value| value == "true"),
                "workerHash": env!("RC_CALL_WORKER_HASH"),
        })
    );
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
}

#[test]
fn failed_worker_sync_prevents_gateway_handoff_and_preserves_installed_selection() {
    let home = tempfile::tempdir().unwrap();
    let bin = home.path().join("localbin/remote-coder-gateway");
    let state = home.path().join(".remote-coder");
    let commands = home.path().join("commands");
    let package = home.path().join("package");
    for path in [&bin, &state, &commands, &package.join("bin")] {
        std::fs::create_dir_all(path).unwrap();
    }
    let claimed = Command::new(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"))
        .args(["runtime", "prepare-gateway-stage", "--stage-id", "7"])
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    assert!(claimed.status.success(), "{claimed:?}");
    let bundle = bin.join("RemoteCoderGateway.app.new.7");
    let staged = bundle.join("Contents/MacOS/remote-coder-codex-gateway");
    std::fs::create_dir_all(staged.parent().unwrap()).unwrap();
    std::fs::write(
        bundle.join("Contents/Info.plist"),
        include_bytes!("../RemoteCoderGateway.template/Contents/Info.plist"),
    )
    .unwrap();
    std::fs::copy(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"), &staged).unwrap();
    let installed = bin.join("remote-coder-codex-gateway");
    let old_binary = b"#!/bin/sh\necho '{\"version\": \"legacy\"}'\n";
    std::fs::write(&installed, old_binary).unwrap();
    std::fs::set_permissions(&installed, std::fs::Permissions::from_mode(0o755)).unwrap();
    let old_worker = home.path().join("old-worker/agent-call");
    std::fs::create_dir_all(old_worker.parent().unwrap()).unwrap();
    std::fs::write(&old_worker, b"old worker").unwrap();
    let host = nix::unistd::gethostname()
        .unwrap()
        .to_string_lossy()
        .split('.')
        .next()
        .unwrap()
        .to_owned();
    let config = serde_json::to_vec(&json!({
        "originGatewayUrl": "ws://127.0.0.1:8765/ws", "workerHost": host,
        "workerPath": old_worker, "workerConfigPath": state.join("carrier.json")
    }))
    .unwrap();
    std::fs::write(state.join("call-delivery.json"), &config).unwrap();
    let compatibility: serde_json::Value =
        serde_json::from_str(include_str!("../../docs/codex/compatibility.json")).unwrap();
    let version = compatibility["codexCliVersion"].as_str().unwrap();
    let codex = package.join("bin/codex");
    let code_host = package.join("bin/codex-code-mode-host");
    std::fs::write(&codex, format!("#!/bin/sh\necho 'codex-cli {version}'\n")).unwrap();
    std::fs::write(&code_host, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::write(package.join("codex-package.json"), serde_json::to_vec(&json!({
        "layoutVersion": 1, "version": version, "sourceCommit": "b".repeat(40),
        "target": "aarch64-apple-darwin", "variant": "codex", "entrypoint": "bin/codex",
        "resourcesDir": "codex-resources", "pathDir": "codex-path",
        "binaries": {
            "bin/codex": {"sha256": format!("{:x}", Sha256::digest(std::fs::read(&codex).unwrap()))},
            "bin/codex-code-mode-host": {"sha256": format!("{:x}", Sha256::digest(std::fs::read(&code_host).unwrap()))}
        }
    })).unwrap()).unwrap();
    std::fs::write(
        commands.join("uv"),
        "#!/bin/sh\necho frozen-sync-rejected >&2\nexit 1\n",
    )
    .unwrap();
    std::fs::write(commands.join("ssh"), "#!/bin/sh\necho '{\"path\": null}'\n").unwrap();
    let mutations = home.path().join("launchctl-actions");
    std::fs::write(
        commands.join("launchctl"),
        format!(
            "#!/bin/sh\necho mutation >> '{}'\nexit 1\n",
            mutations.display()
        ),
    )
    .unwrap();
    for path in [
        &staged,
        &codex,
        &code_host,
        &commands.join("uv"),
        &commands.join("ssh"),
        &commands.join("launchctl"),
    ] {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let env_file = home.path().join("gateway.env");
    let operator_token = format!("{:x}", Sha256::digest(b"gateway build fixture"));
    std::fs::write(&env_file, format!("RC_CODEX_GATEWAY_CODEX_PATH={}\nRC_CODEX_GATEWAY_BIND_HOST=127.0.0.1\nRC_CODEX_GATEWAY_PORT=8765\nRC_CODEX_GATEWAY_AUTH_TOKEN={}\n", codex.display(), operator_token)).unwrap();
    let output = Command::new(&staged)
        .args([
            "--env-file",
            env_file.to_str().unwrap(),
            "runtime",
            "install-gateway",
            "--stage-id",
            "7",
        ])
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", format!("{}:/usr/bin:/bin", commands.display()))
        .current_dir(home.path())
        .output()
        .unwrap();
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Locked worker dependency sync failed"),
        "{output:?}"
    );
    assert_eq!(std::fs::read(&installed).unwrap(), old_binary);
    assert_eq!(std::fs::read(&old_worker).unwrap(), b"old worker");
    assert_eq!(
        std::fs::read(state.join("call-delivery.json")).unwrap(),
        config
    );
    assert!(!mutations.exists());
    assert!(!state.join("codex-restart-recovery.json").exists());
}

#[test]
fn install_worker_cli_emits_only_the_verified_contract_without_startup_banners() {
    let home = tempfile::tempdir().unwrap();
    let commands = home.path().join("commands");
    let state = home.path().join(".remote-coder");
    std::fs::create_dir_all(&commands).unwrap();
    std::fs::create_dir_all(&state).unwrap();
    let host = nix::unistd::gethostname()
        .unwrap()
        .to_string_lossy()
        .split('.')
        .next()
        .unwrap()
        .to_owned();
    std::fs::write(state.join("call-delivery.json"), serde_json::to_vec(&json!({
        "originGatewayUrl": "ws://127.0.0.1:8765/ws", "workerHost": host,
        "workerPath": "/fixture/old-worker/agent-call", "workerConfigPath": "/fixture/carrier.json"
    })).unwrap()).unwrap();
    let python = commands.join("python3");
    std::fs::write(&python, "#!/usr/bin/python3\nimport json, sys\nfrom pathlib import Path\nbundle = json.load(sys.stdin)\nif bundle.get('operation') == 'finish':\n intent = json.loads((Path.home() / '.remote-coder/worker-activation.json').read_text())\n assert bundle['sourceHash'] == intent['sourceHash']\n assert bundle['targetHash'] == intent['targetHash']\n print('{}'); sys.exit(0)\nprint(json.dumps({'reservation': bundle['reservation'], 'workerHash': bundle['workerHash'], 'identity': bundle['identity'], 'protocolVersion': 1, 'workerPath': '/fixture/' + bundle['workerHash'] + '/dev-tools/agent-call'}))\n").unwrap();
    std::fs::set_permissions(&python, std::fs::Permissions::from_mode(0o755)).unwrap();
    let installed = home
        .path()
        .join("localbin/remote-coder-gateway/remote-coder-codex-gateway");
    std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
    let version = installed
        .parent()
        .unwrap()
        .join("versions")
        .join("c".repeat(64));
    let bundle = version.join("RemoteCoderGateway.app");
    let binary = bundle.join("Contents/MacOS/remote-coder-codex-gateway");
    std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
    std::fs::copy(env!("CARGO_BIN_EXE_remote-coder-codex-gateway"), &binary).unwrap();
    std::fs::write(
        bundle.join("Contents/Info.plist"),
        include_bytes!("../RemoteCoderGateway.template/Contents/Info.plist"),
    )
    .unwrap();
    std::fs::copy(
        state.join("call-delivery.json"),
        version.join("call-delivery.json"),
    )
    .unwrap();
    std::fs::write(version.join("pair.json"), serde_json::to_vec(&json!({
        "gatewayHash": format!("{:x}", Sha256::digest(std::fs::read(&binary).unwrap())),
        "configHash": format!("{:x}", Sha256::digest(std::fs::read(version.join("call-delivery.json")).unwrap())),
        "workerHash": env!("RC_CALL_WORKER_HASH")
    })).unwrap()).unwrap();
    std::os::unix::fs::symlink(
        "RemoteCoderGateway.app/Contents/MacOS/remote-coder-codex-gateway",
        version.join("remote-coder-codex-gateway"),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        format!("versions/{}", "c".repeat(64)),
        installed.parent().unwrap().join("current"),
    )
    .unwrap();
    std::os::unix::fs::symlink("current/remote-coder-codex-gateway", &installed).unwrap();
    std::fs::write(
        state.join("worker-activation.json"),
        serde_json::to_vec(&json!({
            "host": host, "origin": host, "generation": "00000000-0000-0000-0000-000000000001",
            "sourceHash": env!("RC_CALL_WORKER_HASH"), "targetHash": "b".repeat(64)
        }))
        .unwrap(),
    )
    .unwrap();
    let output = Command::new(installed)
        .args(["runtime", "install-call-worker"])
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", format!("{}:/usr/bin:/bin", commands.display()))
        .current_dir(home.path())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["workerHash"], env!("RC_CALL_WORKER_HASH"));
    assert_eq!(result["protocolVersion"], 1);
    assert!(!home.path().join("Library/Logs").exists());
}
