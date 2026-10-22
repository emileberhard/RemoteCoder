use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::Value;

#[path = "src/build_identity/inputs.rs"]
mod identity_inputs;

#[path = "src/call_worker/manifest.rs"]
mod worker_manifest;

fn main() {
    for name in [
        "RC_RELEASE_VERSION",
        "RC_SOURCE_COMMIT",
        "RC_SOURCE_MODIFIED",
        "RC_BUILD_PROVENANCE",
    ] {
        println!("cargo::rerun-if-env-changed={name}");
    }
    println!("cargo::rerun-if-changed=src/build_identity/inputs.rs");
    let release = identity_input("RC_RELEASE_VERSION");
    let commit = identity_input("RC_SOURCE_COMMIT");
    let modified = identity_input("RC_SOURCE_MODIFIED");
    let identity =
        identity_inputs::parse(release.as_deref(), commit.as_deref(), modified.as_deref())
            .unwrap_or_else(|error| panic!("invalid gateway build identity: {error}"));
    let output = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo OUT_DIR"));
    let manifest_dir =
        PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("Cargo CARGO_MANIFEST_DIR"));
    let bundle = manifest_dir.join("RemoteCoderGateway.template");
    let plist = bundle.join("Contents/Info.plist");
    println!("cargo::rerun-if-changed={}", plist.display());
    let plist_json = std::process::Command::new("plutil")
        .args(["-convert", "json", "-o", "-"])
        .arg(&plist)
        .output()
        .expect("gateway bundle metadata");
    assert!(
        plist_json.status.success(),
        "invalid gateway bundle metadata"
    );
    let metadata: Value = serde_json::from_slice(&plist_json.stdout).expect("gateway bundle JSON");
    println!(
        "cargo::rustc-env=RC_GATEWAY_BUNDLE_NAME={}",
        bundle
            .with_extension("app")
            .file_name()
            .expect("bundle name")
            .to_str()
            .expect("UTF-8 bundle name")
    );
    println!(
        "cargo::rustc-env=RC_GATEWAY_EXECUTABLE_NAME={}",
        metadata["CFBundleExecutable"]
            .as_str()
            .expect("gateway executable name")
    );
    let root = manifest_dir.parent().expect("repository root");
    let names: Vec<String> = if let Some(provenance) = std::env::var_os("RC_BUILD_PROVENANCE") {
        println!(
            "cargo::rerun-if-changed={}",
            Path::new(&provenance).display()
        );
        let record: Value =
            serde_json::from_slice(&std::fs::read(provenance).expect("build provenance"))
                .expect("build provenance JSON");
        serde_json::from_value(record["callWorkerFiles"].clone())
            .expect("tracked call worker files in source provenance")
    } else {
        let tracked = std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args([
                "ls-files",
                "--cached",
                "-z",
                "agent-calls/agent_calls",
                "dev-tools/src",
                "agent-calls/pyproject.toml",
                "agent-calls/uv.lock",
                "dev-tools/pyproject.toml",
                "dev-tools/uv.lock",
                "dev-tools/agent-call",
            ])
            .output()
            .expect("tracked call worker sources");
        assert!(
            tracked.status.success(),
            "call worker source inventory failed"
        );
        String::from_utf8(tracked.stdout)
            .expect("worker source paths")
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(str::to_owned)
            .collect()
    };
    assert!(
        !names.is_empty() && names.len() <= 128,
        "worker source inventory exceeds its capacity"
    );
    let mut remaining = 4 * 1024 * 1024;
    let mut files = Vec::new();
    for name in &names {
        let allowed = matches!(
            name.as_str(),
            "agent-calls/pyproject.toml"
                | "agent-calls/uv.lock"
                | "dev-tools/pyproject.toml"
                | "dev-tools/uv.lock"
                | "dev-tools/agent-call"
        ) || (name.ends_with(".py")
            && (name.starts_with("agent-calls/agent_calls/")
                || name.starts_with("dev-tools/src/remotecoder_tools/")));
        assert!(allowed, "unsupported tracked worker source: {name}");
        let path = root.join(name);
        assert!(
            !std::fs::symlink_metadata(&path)
                .expect("worker source metadata")
                .file_type()
                .is_symlink(),
            "worker sources cannot be links"
        );
        println!("cargo::rerun-if-changed={}", path.display());
        let mut bytes = Vec::new();
        std::fs::File::open(&path)
            .expect("worker source")
            .take(remaining as u64 + 1)
            .read_to_end(&mut bytes)
            .expect("bounded worker source read");
        assert!(
            bytes.len() <= remaining,
            "worker source inventory exceeds its capacity"
        );
        remaining -= bytes.len();
        files.push((name.as_str(), bytes));
    }
    for directory in [
        "agent-calls/agent_calls",
        "dev-tools/src/remotecoder_tools",
        "host-daemon-rs/src/call_worker/manifest.rs",
    ] {
        println!("cargo::rerun-if-changed={}", root.join(directory).display());
    }
    let identity_json = serde_json::to_vec(&serde_json::json!({"version": identity.version, "commit": identity.commit, "modified": identity.modified})).expect("worker build identity");
    let references = files
        .iter()
        .map(|(path, bytes)| (*path, bytes.as_slice()))
        .collect::<Vec<_>>();
    let worker_hash =
        worker_manifest::content_hash(&identity_json, &references).expect("bounded worker table");
    let entries = names
        .iter()
        .map(|name| {
            format!(
                "({name:?}, include_bytes!({:?}).as_slice()),",
                root.join(name)
            )
        })
        .collect::<String>();
    std::fs::write(
        output.join("call_worker_files.rs"),
        format!("pub(crate) const FILES: &[(&str, &[u8])] = &[{entries}];"),
    )
    .expect("worker file table");
    println!("cargo::rustc-env=RC_CALL_WORKER_HASH={worker_hash}");

    std::fs::write(
        output.join("gateway_identity.rs"),
        format!(
            "pub(crate) const IDENTITY: BuildIdentity = BuildIdentity {{ version: {:?}, commit: {:?}, modified: {:?}, worker_hash: {:?} }};",
            identity.version, identity.commit, identity.modified, worker_hash
        ),
    ).expect("write gateway build identity");

    let path = manifest_dir.join("../docs/codex/compatibility.json");
    println!("cargo::rerun-if-changed={}", path.display());
    let record: Value = serde_json::from_str(
        &std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display())),
    )
    .unwrap_or_else(|error| panic!("invalid JSON in {}: {error}", path.display()));
    for (name, pointer) in [
        ("RC_REQUIRED_CODEX_VERSION", "/codexCliVersion"),
        ("RC_REQUIRED_CODEX_SOURCE_COMMIT", "/codexForkCommit"),
        ("RC_REQUIRED_CODEX_SHA256", "/runtimeHashes/bin~1codex"),
        (
            "RC_REQUIRED_CODE_MODE_HOST_SHA256",
            "/runtimeHashes/bin~1codex-code-mode-host",
        ),
    ] {
        let value = record
            .pointer(pointer)
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("{} has no string at {pointer}", path.display()));
        println!("cargo::rustc-env={name}={value}");
    }
}

fn identity_input(name: &str) -> Option<String> {
    match std::env::var(name) {
        Ok(value) => Some(value),
        Err(std::env::VarError::NotPresent) => None,
        Err(std::env::VarError::NotUnicode(_)) => panic!("{name} must be UTF-8"),
    }
}
