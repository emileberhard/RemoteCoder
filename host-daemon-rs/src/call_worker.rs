use anyhow::{Result, ensure};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

mod manifest;
include!(concat!(env!("OUT_DIR"), "/call_worker_files.rs"));

pub(crate) fn bundle(previous_hash: Option<&str>) -> Result<Value> {
    let identity = json!({"version": crate::build_identity::IDENTITY.version,
        "commit": crate::build_identity::IDENTITY.commit,
        "modified": crate::build_identity::IDENTITY.modified});
    let hash = manifest::content_hash(&serde_json::to_vec(&identity)?, FILES)
        .map_err(anyhow::Error::msg)?;
    ensure!(
        hash == crate::build_identity::IDENTITY.worker_hash,
        "Embedded worker content hash mismatch"
    );
    let files = FILES
        .iter()
        .map(|(path, data)| ((*path).to_owned(), Value::String(STANDARD.encode(data))))
        .collect::<serde_json::Map<String, Value>>();
    Ok(
        json!({"identity": identity, "workerHash": hash, "previousHash": previous_hash, "files": files}),
    )
}
