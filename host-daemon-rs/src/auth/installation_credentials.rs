//! Installation tokens are separate from the operator credential. Only the
//! operator or a revocation-bound enrollment capability can enroll; retries are idempotent.
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use clap::Subcommand;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::sync::Semaphore;

const MAX_BYTES: u64 = 1024 * 1024;

#[derive(Clone, Debug, Subcommand)]
pub(crate) enum CredentialCommand {
    /// Write a new installation token to a new mode-0600 file; never stdout.
    Issue {
        #[arg(long)]
        label: String,
        #[arg(long)]
        output: PathBuf,
    },
    /// List installation IDs and revocation state, without secrets or hashes.
    List,
    /// Revoke one installation. Connected clients close on their next lease check.
    Revoke { id: String },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Enrollment {
    pub installation_id: String,
    pub label: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    label: String,
    digest: String,
    created_at: u64,
    revoked: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    parent: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u32,
    records: BTreeMap<String, Record>,
}

impl Default for Document {
    fn default() -> Self {
        Self {
            schema_version: 1,
            records: BTreeMap::new(),
        }
    }
}

#[derive(Clone)]
pub(crate) struct InstallationCredentials {
    path: PathBuf,
    admission: Arc<Semaphore>,
    members: Arc<crate::cluster::members::Members>,
}

#[derive(Debug, Clone)]
pub(crate) enum Grant {
    Operator,
    Peer {
        host: String,
        membership: String,
        digest: String,
    },
    Installation {
        id: String,
        digest: String,
    },
}

pub(crate) fn operator_matches(presented: &str, operator: &str) -> bool {
    !presented.is_empty()
        && !operator.is_empty()
        && bool::from(
            Sha256::digest(presented.as_bytes()).ct_eq(&Sha256::digest(operator.as_bytes())),
        )
}

fn digest(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

pub(crate) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

impl InstallationCredentials {
    pub(crate) fn default_path() -> Result<PathBuf> {
        Ok(crate::config::HostPaths::from_env()?.state("installation-credentials.json"))
    }

    pub fn new(path: PathBuf, members: Arc<crate::cluster::members::Members>) -> Self {
        Self {
            path,
            members,
            admission: Arc::new(Semaphore::new(8)),
        }
    }

    pub(crate) async fn authenticate(&self, token: &str, operator: &str) -> Result<Option<Grant>> {
        if operator_matches(token, operator) {
            return Ok(Some(Grant::Operator));
        }
        if token.starts_with("rcp1.") {
            return self.members.authenticate(token).await;
        }
        let Some(rest) = token.strip_prefix("rc1.") else {
            return Ok(None);
        };
        let Some((id, _)) = rest.split_once('.') else {
            return Ok(None);
        };
        if !valid_id(id) || token.len() > 256 {
            return Ok(None);
        }
        let grant = Grant::Installation {
            id: id.to_owned(),
            digest: digest(token),
        };
        Ok(self.is_valid(&grant).await?.then_some(grant))
    }

    pub(crate) async fn is_valid(&self, grant: &Grant) -> Result<bool> {
        if let Grant::Peer {
            host,
            membership,
            digest,
        } = grant
        {
            return self.members.valid(host, membership, digest).await;
        }
        let Grant::Installation { id, digest } = grant else {
            return Ok(true);
        };
        let id = id.clone();
        let digest = digest.clone();
        self.transaction(move |document| {
            Ok((
                document.records.get(&id).is_some_and(|record| {
                    active(document, &id)
                        && bool::from(record.digest.as_bytes().ct_eq(digest.as_bytes()))
                }),
                false,
            ))
        })
        .await
    }

    pub(crate) async fn enroll(&self, request: Enrollment, operator: &str) -> Result<String> {
        ensure!(
            valid_id(&request.installation_id),
            "invalid installation ID"
        );
        ensure!(
            !request.label.trim().is_empty() && request.label.len() <= 128,
            "invalid installation label"
        );
        ensure!(!operator.is_empty(), "operator enrollment is unavailable");
        // HKDF gives this authenticated enrollment its stable retry result without
        // retaining recoverable installation secrets in the host store.
        let mut secret = [0_u8; 32];
        Hkdf::<Sha256>::new(Some(b"RemoteCoder installation v1"), operator.as_bytes())
            .expand(request.installation_id.as_bytes(), &mut secret)
            .map_err(|_| anyhow::anyhow!("installation derivation failed"))?;
        let token = format!(
            "rc1.{}.{}",
            request.installation_id,
            URL_SAFE_NO_PAD.encode(secret)
        );
        self.register(request.installation_id, request.label, token)
            .await
    }

    pub(crate) async fn sharing_credential(
        &self,
        grant: Grant,
        operator: String,
    ) -> Result<String> {
        let Grant::Installation { id, digest } = grant else {
            anyhow::bail!("an installation credential is required to share enrollment");
        };
        self.transaction(move |document| {
            let record = document.records.get(&id).context("unknown installation")?;
            ensure!(
                active(document, &id)
                    && bool::from(record.digest.as_bytes().ct_eq(digest.as_bytes())),
                "installation is no longer authorized"
            );
            Ok((sharing_token(&id, record, &operator)?, false))
        })
        .await
    }

    pub(crate) async fn can_enroll(&self, token: String, operator: String) -> Result<bool> {
        if operator_matches(&token, &operator) {
            return Ok(true);
        }
        self.transaction(move |document| {
            Ok((
                sharing_parent(document, &token, &operator)?.is_some(),
                false,
            ))
        })
        .await
    }

    pub(crate) async fn enroll_shared(
        &self,
        request: Enrollment,
        token: String,
        operator: String,
    ) -> Result<String> {
        ensure!(
            valid_id(&request.installation_id),
            "invalid installation ID"
        );
        ensure!(
            !request.label.trim().is_empty() && request.label.len() <= 128,
            "invalid installation label"
        );
        self.transaction(move |document| {
            let parent = sharing_parent(document, &token, &operator)?
                .context("enrollment credential is no longer authorized")?;
            let mut secret = [0_u8; 32];
            Hkdf::<Sha256>::new(
                Some(b"RemoteCoder delegated installation v1"),
                token.as_bytes(),
            )
            .expand(request.installation_id.as_bytes(), &mut secret)
            .map_err(|_| anyhow::anyhow!("installation derivation failed"))?;
            let token = format!(
                "rc1.{}.{}",
                request.installation_id,
                URL_SAFE_NO_PAD.encode(secret)
            );
            register(
                document,
                request.installation_id,
                request.label,
                token,
                Some(parent),
            )
        })
        .await
    }

    async fn register(&self, id: String, label: String, token: String) -> Result<String> {
        self.transaction(move |document| register(document, id, label, token, None))
            .await
    }

    pub(crate) async fn revoke(&self, id: String) -> Result<bool> {
        self.transaction(move |document| {
            let Some(record) = document.records.get_mut(&id) else {
                return Ok((false, false));
            };
            record.revoked = true;
            Ok((true, true))
        })
        .await
    }

    async fn transaction<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Document) -> Result<(T, bool)> + Send + 'static,
    ) -> Result<T> {
        let path = self.path.clone();
        let permit = Arc::clone(&self.admission).acquire_owned().await?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            crate::storage::private_state::transaction(
                &path,
                "credential path has no parent",
                load,
                operation,
                |path, document| {
                    ensure!(
                        serde_json::to_vec(document)?.len() as u64 <= MAX_BYTES,
                        "credential store capacity exceeded"
                    );
                    crate::storage::private_state::write_json(path, document)
                },
            )
        })
        .await
        .context("credential storage worker failed")?
    }
}

fn active(document: &Document, id: &str) -> bool {
    let mut next = id;
    for _ in 0..document.records.len() {
        let Some(record) = document.records.get(next) else {
            return false;
        };
        if record.revoked {
            return false;
        }
        let Some(parent) = record.parent.as_deref() else {
            return true;
        };
        next = parent;
    }
    false
}

fn sharing_token(id: &str, record: &Record, operator: &str) -> Result<String> {
    ensure!(!operator.is_empty(), "operator enrollment is unavailable");
    let mut secret = [0_u8; 32];
    Hkdf::<Sha256>::new(
        Some(b"RemoteCoder shared enrollment v1"),
        operator.as_bytes(),
    )
    .expand(format!("{id}.{}", record.digest).as_bytes(), &mut secret)
    .map_err(|_| anyhow::anyhow!("enrollment derivation failed"))?;
    Ok(format!("rcs1.{id}.{}", URL_SAFE_NO_PAD.encode(secret)))
}

fn sharing_parent(document: &Document, token: &str, operator: &str) -> Result<Option<String>> {
    let Some((id, _)) = token
        .strip_prefix("rcs1.")
        .and_then(|rest| rest.split_once('.'))
    else {
        return Ok(None);
    };
    if !valid_id(id) || token.len() > 256 || !active(document, id) {
        return Ok(None);
    }
    let record = document
        .records
        .get(id)
        .context("unknown enrollment parent")?;
    Ok(operator_matches(token, &sharing_token(id, record, operator)?).then(|| id.to_owned()))
}

fn register(
    document: &mut Document,
    id: String,
    label: String,
    token: String,
    parent: Option<String>,
) -> Result<(String, bool)> {
    let hash = digest(&token);
    if let Some(existing) = document.records.get(&id) {
        ensure!(
            !existing.revoked,
            "installation was revoked; provision a new installation ID explicitly"
        );
        ensure!(
            existing.digest == hash && existing.parent == parent && active(document, &id),
            "installation ID already belongs to another credential"
        );
        return Ok((token, false));
    }
    ensure!(
        document.records.len() < 4096,
        "installation credential capacity reached"
    );
    document.records.insert(
        id,
        Record {
            label,
            digest: hash,
            created_at: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
            revoked: false,
            parent,
        },
    );
    Ok((token, true))
}

fn load(path: &Path) -> Result<Document> {
    use crate::storage::private_state::ReadError;

    let Some(bytes) = crate::storage::private_state::read_bounded(path, MAX_BYTES).map_err(
        |error| match error {
            ReadError::Io(error) => error.into(),
            ReadError::NotRegular => anyhow::anyhow!("credential store must be a regular file"),
            ReadError::TooLargeBeforeRead | ReadError::TooLargeAfterRead => {
                anyhow::anyhow!("credential store is oversized")
            }
        },
    )?
    else {
        return Ok(Document::default());
    };
    let document: Document = serde_json::from_slice(&bytes)
        .context("unreadable credential store; original preserved")?;
    ensure!(
        document.schema_version == 1,
        "unsupported credential store version"
    );
    for (id, record) in &document.records {
        ensure!(
            valid_id(id)
                && record.digest.len() == 43
                && record.parent.as_ref().is_none_or(|parent| valid_id(parent)),
            "invalid installation credential record"
        );
    }
    Ok(document)
}

pub(crate) async fn run(command: CredentialCommand) -> Result<()> {
    let path = InstallationCredentials::default_path()?;
    let members = Arc::new(crate::cluster::members::Members::new(
        path.parent().context("credential store has no parent")?,
    ));
    let store = InstallationCredentials::new(path, members);
    match command {
        CredentialCommand::Issue { label, output } => {
            ensure!(
                !label.trim().is_empty() && label.len() <= 128,
                "invalid installation label"
            );
            let mut random = [0_u8; 48];
            getrandom::fill(&mut random).expect("operating system entropy");
            let id = URL_SAFE_NO_PAD.encode(&random[..16]);
            let token = format!("rc1.{id}.{}", URL_SAFE_NO_PAD.encode(&random[16..]));
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .custom_flags(libc::O_NOFOLLOW)
                .mode(0o600)
                .open(&output)?;
            let result = async {
                file.write_all(token.as_bytes())?;
                file.sync_all()?;
                store.register(id.clone(), label, token).await?;
                Ok::<(), anyhow::Error>(())
            }
            .await;
            if result.is_err() {
                let _ = fs::remove_file(&output);
            }
            result?;
            println!(
                "{}",
                serde_json::json!({"installationId": id, "tokenFile": output})
            );
        }
        CredentialCommand::List => {
            let entries = store.transaction(|document| Ok((document.records.iter().map(|(id, record)|
                serde_json::json!({"installationId": id, "label": record.label, "createdAt": record.created_at, "revoked": !active(document, id), "parent": record.parent}))
                .collect::<Vec<_>>(), false))).await?;
            println!("{}", serde_json::to_string(&entries)?);
        }
        CredentialCommand::Revoke { id } => {
            let found = store.revoke(id.clone()).await?;
            ensure!(found, "unknown installation ID");
            println!(
                "{}",
                serde_json::json!({"installationId": id, "revoked": true})
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn enrollment_is_idempotent_revocable_and_stores_only_a_digest() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.json");
        let store = InstallationCredentials::new(
            path.clone(),
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        let enroll = || Enrollment {
            installation_id: "phone-1".into(),
            label: "Test phone".into(),
        };
        let token = store
            .enroll(enroll(), "synthetic-operator-credential")
            .await
            .unwrap();
        assert_eq!(
            token,
            store
                .enroll(enroll(), "synthetic-operator-credential")
                .await
                .unwrap()
        );
        assert!(!fs::read_to_string(&path).unwrap().contains(&token));
        let grant = store
            .authenticate(&token, "synthetic-operator-credential")
            .await
            .unwrap()
            .unwrap();
        let other_process = InstallationCredentials::new(
            path,
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        assert!(other_process.revoke("phone-1".into()).await.unwrap());
        assert!(!store.is_valid(&grant).await.unwrap());
        assert!(
            store
                .authenticate(&token, "synthetic-operator-credential")
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            store
                .enroll(enroll(), "synthetic-operator-credential")
                .await
                .is_err()
        );
        assert!(
            store
                .authenticate(
                    "synthetic-operator-credential",
                    "synthetic-operator-credential"
                )
                .await
                .unwrap()
                .is_some()
        );
    }

    #[tokio::test]
    async fn sharing_enrolls_distinct_devices_and_revocation_cannot_be_escaped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.json");
        let store = InstallationCredentials::new(
            path.clone(),
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        let request = |id: &str| Enrollment {
            installation_id: id.into(),
            label: "Test device".into(),
        };
        let phone = store.enroll(request("phone"), "operator").await.unwrap();
        let phone_grant = store
            .authenticate(&phone, "operator")
            .await
            .unwrap()
            .unwrap();
        let shared = store
            .sharing_credential(phone_grant, "operator".into())
            .await
            .unwrap();
        assert!(
            store
                .authenticate(&shared, "operator")
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            !store
                .can_enroll(phone.clone(), "operator".into())
                .await
                .unwrap()
        );
        assert!(
            !store
                .can_enroll(format!("{shared}x"), "operator".into())
                .await
                .unwrap()
        );
        let mac = store
            .enroll_shared(request("mac"), shared.clone(), "operator".into())
            .await
            .unwrap();
        assert_eq!(
            mac,
            store
                .enroll_shared(request("mac"), shared.clone(), "operator".into())
                .await
                .unwrap()
        );
        assert!(
            store
                .enroll_shared(request("phone"), shared.clone(), "operator".into())
                .await
                .is_err()
        );
        let tablet = store
            .enroll_shared(request("tablet"), shared.clone(), "operator".into())
            .await
            .unwrap();
        let mac_grant = store.authenticate(&mac, "operator").await.unwrap().unwrap();
        let mac_shared = store
            .sharing_credential(mac_grant.clone(), "operator".into())
            .await
            .unwrap();
        let descendant = store
            .enroll_shared(request("descendant"), mac_shared.clone(), "operator".into())
            .await
            .unwrap();
        let descendant_grant = store
            .authenticate(&descendant, "operator")
            .await
            .unwrap()
            .unwrap();
        assert!(store.revoke("mac".into()).await.unwrap());
        assert!(!store.is_valid(&mac_grant).await.unwrap());
        assert!(!store.is_valid(&descendant_grant).await.unwrap());
        assert!(
            !store
                .can_enroll(mac_shared, "operator".into())
                .await
                .unwrap()
        );
        assert!(
            store
                .enroll_shared(request("mac"), shared.clone(), "operator".into())
                .await
                .is_err()
        );
        assert!(
            store
                .authenticate(&tablet, "operator")
                .await
                .unwrap()
                .is_some()
        );
        let other = InstallationCredentials::new(
            path.clone(),
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        assert!(other.revoke("phone".into()).await.unwrap());
        assert!(
            store
                .authenticate(&tablet, "operator")
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            !store
                .can_enroll(shared.clone(), "operator".into())
                .await
                .unwrap()
        );
        assert!(
            store
                .enroll_shared(request("escape"), shared.clone(), "operator".into())
                .await
                .is_err()
        );
        let saved = fs::read_to_string(&path).unwrap();
        for secret in [phone, shared, mac, tablet, descendant] {
            assert!(!saved.contains(&secret));
        }
    }

    #[tokio::test]
    async fn repeated_enrollment_does_not_rewrite_the_store() {
        use std::os::unix::fs::MetadataExt;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.json");
        let store = InstallationCredentials::new(
            path.clone(),
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        let enroll = || Enrollment {
            installation_id: "phone-1".into(),
            label: "Test phone".into(),
        };
        store.enroll(enroll(), "operator").await.unwrap();
        let published = fs::metadata(&path).unwrap().ino();
        store.enroll(enroll(), "operator").await.unwrap();
        assert_eq!(fs::metadata(&path).unwrap().ino(), published);
    }

    #[tokio::test]
    async fn malformed_storage_is_not_empty_and_independent_enrollments_survive() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.json");
        let first = InstallationCredentials::new(
            path.clone(),
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        let second = InstallationCredentials::new(
            path.clone(),
            Arc::new(crate::cluster::members::Members::new(dir.path())),
        );
        let (a, b) = tokio::join!(
            first.enroll(
                Enrollment {
                    installation_id: "a".into(),
                    label: "A".into()
                },
                "operator"
            ),
            second.enroll(
                Enrollment {
                    installation_id: "b".into(),
                    label: "B".into()
                },
                "operator"
            )
        );
        assert!(
            first
                .authenticate(&a.unwrap(), "operator")
                .await
                .unwrap()
                .is_some()
        );
        assert!(
            first
                .authenticate(&b.unwrap(), "operator")
                .await
                .unwrap()
                .is_some()
        );
        fs::write(&path, b"unreadable").unwrap();
        assert!(first.revoke("a".into()).await.is_err());
        assert_eq!(fs::read(&path).unwrap(), b"unreadable");
        assert!(!operator_matches("", ""));
    }
}
