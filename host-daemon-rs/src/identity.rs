use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use crate::storage::private_state::{self, ReadError};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HostIdentity {
    pub host_id: String,
    pub incarnation: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u32,
    identity: HostIdentity,
    job_epoch: String,
    receipt_epoch: String,
}

fn read(path: &Path) -> Result<Option<Vec<u8>>> {
    private_state::read_bounded(path, 4096).map_err(|error| match error {
        ReadError::Io(error) => error.into(),
        error => anyhow::anyhow!("invalid identity state {}: {error:?}", path.display()),
    })
}

fn uuid(value: &str) -> Result<()> {
    ensure!(
        crate::ids::parse_uuid(value).is_some(),
        "invalid host identity UUID"
    );
    Ok(())
}

fn epoch(root: &Path) -> Result<String> {
    private_state::ensure_private_directory(root)?;
    let path = root.join(".epoch");
    if read(&path)?.is_none() {
        private_state::create_new(&path, crate::ids::new_session_uuid().as_bytes())?;
    }
    let bytes = read(&path)?.context("store epoch disappeared")?;
    if let Ok(value) = String::from_utf8(bytes)
        && crate::ids::parse_uuid(&value).is_some()
    {
        return Ok(value);
    }
    let value = crate::ids::new_session_uuid();
    private_state::replace(&path, value.as_bytes())?;
    Ok(value)
}

pub(crate) fn open(state: &Path, receipt_root: &Path) -> Result<HostIdentity> {
    let path = state.join("identity/v1");
    private_state::transaction(
        &path,
        "identity path has no parent",
        |path| {
            read(path)?
                .map(|bytes| serde_json::from_slice::<Document>(&bytes).map_err(Into::into))
                .transpose()
        },
        |document| {
            let job_epoch = epoch(&state.join("agent-jobs/v1"))?;
            let receipt_epoch = epoch(receipt_root)?;
            let mut changed = false;
            let document = document.get_or_insert_with(|| {
                changed = true;
                Document {
                    schema_version: 1,
                    identity: HostIdentity {
                        host_id: crate::ids::new_session_uuid(),
                        incarnation: crate::ids::new_session_uuid(),
                    },
                    job_epoch: job_epoch.clone(),
                    receipt_epoch: receipt_epoch.clone(),
                }
            });
            ensure!(
                document.schema_version == 1,
                "unsupported host identity version"
            );
            uuid(&document.identity.host_id)?;
            uuid(&document.identity.incarnation)?;
            if document.job_epoch != job_epoch || document.receipt_epoch != receipt_epoch {
                document.identity.incarnation = crate::ids::new_session_uuid();
                document.job_epoch = job_epoch;
                document.receipt_epoch = receipt_epoch;
                changed = true;
            }
            Ok((document.identity.clone(), changed))
        },
        private_state::write_json,
    )
}

pub(crate) fn invalidate(state: &Path) -> Result<()> {
    let path = state.join("identity/v1");
    private_state::transaction(
        &path,
        "identity path has no parent",
        |path| {
            serde_json::from_slice::<Document>(&read(path)?.context("host identity is missing")?)
                .map_err(Into::into)
        },
        |document| {
            document.identity.incarnation = crate::ids::new_session_uuid();
            Ok(((), true))
        },
        private_state::write_json,
    )
}

pub(crate) fn reset(state: &Path) -> Result<HostIdentity> {
    let path = state.join("identity/v1");
    private_state::transaction(
        &path,
        "identity path has no parent",
        |path| {
            serde_json::from_slice::<Document>(&read(path)?.context("host identity missing")?)
                .map_err(Into::into)
        },
        |document| {
            document.identity = HostIdentity {
                host_id: crate::ids::new_session_uuid(),
                incarnation: crate::ids::new_session_uuid(),
            };
            Ok((document.identity.clone(), true))
        },
        private_state::write_json,
    )
}

pub(crate) fn receipt_root(home: &Path) -> PathBuf {
    home.join("remotecoder-history")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_survives_restart_and_key_rotation_but_epochs_fence_restores() {
        let root = tempfile::tempdir().unwrap();
        let state = root.path().join("state");
        let receipts = receipt_root(&root.path().join("claude"));
        let first = open(&state, &receipts).unwrap();
        assert_eq!(open(&state, &receipts).unwrap(), first);
        private_state::replace(&state.join("operator-key"), b"rotated-key").unwrap();
        assert_eq!(open(&state, &receipts).unwrap(), first);
        for store in [state.join("agent-jobs/v1"), receipts.clone()] {
            let previous = open(&state, &receipts).unwrap();
            private_state::replace(
                &store.join(".epoch"),
                crate::ids::new_session_uuid().as_bytes(),
            )
            .unwrap();
            let restored = open(&state, &receipts).unwrap();
            assert_eq!(restored.host_id, first.host_id);
            assert_ne!(restored.incarnation, previous.incarnation);
        }
        let previous = open(&state, &receipts).unwrap();
        std::fs::remove_file(receipts.join(".epoch")).unwrap();
        assert_ne!(
            open(&state, &receipts).unwrap().incarnation,
            previous.incarnation
        );
        let previous = open(&state, &receipts).unwrap();
        private_state::replace(&receipts.join(".epoch"), b"inconsistent").unwrap();
        let repaired = open(&state, &receipts).unwrap();
        assert_eq!(repaired.host_id, first.host_id);
        assert_ne!(repaired.incarnation, previous.incarnation);
        invalidate(&state).unwrap();
        assert_ne!(
            open(&state, &receipts).unwrap().incarnation,
            first.incarnation
        );
    }
}
