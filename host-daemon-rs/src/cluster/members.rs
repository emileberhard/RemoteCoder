use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::sync::{OnceCell, watch};

use crate::storage::private_state::{self, ReadError};
use crate::wire::cluster::*;

const MAX_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct Members {
    path: PathBuf,
    snapshot: Arc<OnceCell<Mutex<Arc<Snapshot>>>>,
    changes: watch::Sender<u64>,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    records: BTreeMap<String, MemberRecord>,
}

struct Snapshot {
    document: Document,
    selectors: HashMap<String, Vec<String>>,
}

impl Snapshot {
    fn new(document: Document) -> Result<Self> {
        ensure!(
            document.records.len() <= 4096,
            "membership capacity reached"
        );
        let mut selectors: HashMap<String, Vec<String>> = HashMap::new();
        for (membership, record) in &document.records {
            if record.state == MemberState::Removed {
                continue;
            }
            selectors
                .entry(record.host.clone())
                .or_default()
                .push(membership.clone());
            if record.name != record.host {
                selectors
                    .entry(record.name.clone())
                    .or_default()
                    .push(membership.clone());
            }
        }
        Ok(Self {
            document,
            selectors,
        })
    }
}

#[derive(Debug)]
pub(crate) struct MembershipRemoved {
    pub(crate) host: String,
    pub(crate) membership: String,
}

impl MembershipRemoved {
    pub(crate) fn data(&self) -> serde_json::Value {
        serde_json::json!({"class":"refused","kind":"membership_removed","host":self.host,"membership":self.membership,"retryable":false})
    }
}

impl std::fmt::Display for MembershipRemoved {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("membership was removed")
    }
}

impl std::error::Error for MembershipRemoved {}

pub(crate) fn digest(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

fn load(path: &Path) -> Result<Document> {
    let bytes = private_state::read_bounded(path, MAX_BYTES).map_err(|error| match error {
        ReadError::Io(error) => anyhow::Error::from(error),
        error => anyhow::anyhow!("invalid cluster membership state: {error:?}"),
    })?;
    match bytes {
        Some(bytes) => {
            serde_json::from_slice(&bytes).context("invalid cluster membership document")
        }
        None => Ok(Document::default()),
    }
}

pub(crate) fn validate_uuid(value: &str) -> Result<()> {
    ensure!(crate::ids::parse_uuid(value).is_some(), "expected a UUID");
    Ok(())
}

fn validate_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 64
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "member name must contain 1–64 letters, digits, hyphens or underscores"
    );
    Ok(())
}

impl Members {
    pub(crate) fn new(state: &Path) -> Self {
        Self {
            path: state.join("cluster/v1/members.json"),
            snapshot: Arc::new(OnceCell::new()),
            changes: watch::channel(0).0,
        }
    }

    async fn snapshot(&self) -> Result<Arc<Snapshot>> {
        let cache = self
            .snapshot
            .get_or_try_init(|| async {
                let path = self.path.clone();
                tokio::task::spawn_blocking(move || {
                    Ok::<_, anyhow::Error>(Mutex::new(Arc::new(Snapshot::new(load(&path)?)?)))
                })
                .await?
            })
            .await?;
        let snapshot = cache
            .lock()
            .map_err(|_| anyhow::anyhow!("membership snapshot lock poisoned"))?
            .clone();
        Ok(snapshot)
    }

    pub(crate) async fn changes(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    async fn transaction<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Document) -> Result<(T, bool)> + Send + 'static,
    ) -> Result<T> {
        self.snapshot().await?;
        let path = self.path.clone();
        let snapshot = self.snapshot.clone();
        let changes = self.changes.clone();
        tokio::task::spawn_blocking(move || {
            let cache = snapshot.get().context("membership snapshot not initialized")?;
            private_state::transaction(
                &path,
                "membership path has no parent",
                |_| {
                    let current = cache.lock().map_err(|_| anyhow::anyhow!("membership snapshot lock poisoned"))?.clone();
                    Ok(current)
                },
                |current| {
                    let mut document = current.document.clone();
                    let (result, changed) = operation(&mut document)?;
                    if changed {
                        *current = Arc::new(Snapshot::new(document)?);
                    }
                    Ok((result, changed))
                },
                |path, current| {
                    ensure!(serde_json::to_vec(&current.document)?.len() as u64 <= MAX_BYTES, "membership capacity exceeded; retained removal tombstones cannot be discarded");
                    private_state::write_json(path, &current.document)?;
                    let previous = {
                        let mut cached = cache.lock().map_err(|_| anyhow::anyhow!("membership snapshot lock poisoned"))?;
                        std::mem::replace(&mut *cached, current.clone())
                    };
                    drop(previous);
                    changes.send_modify(|revision| *revision = revision.wrapping_add(1));
                    Ok(())
                },
            )
        }).await?
    }

    pub(crate) async fn all(&self) -> Result<Vec<MemberRecord>> {
        let snapshot = self.snapshot().await?;
        Ok(snapshot.document.records.values().cloned().collect())
    }

    pub(crate) async fn resolve(&self, selector: &str) -> Result<MemberRecord> {
        let snapshot = self.snapshot().await?;
        let memberships = snapshot
            .selectors
            .get(selector)
            .context("unknown or removed member")?;
        ensure!(memberships.len() == 1, "member selector is ambiguous");
        snapshot
            .document
            .records
            .get(&memberships[0])
            .cloned()
            .context("member selector index is inconsistent")
    }

    pub(crate) async fn issue(&self, request: IssueParams) -> Result<String> {
        ensure!(request.protocol == PROTOCOL, "unsupported cluster protocol");
        validate_uuid(&request.r#for)?;
        validate_uuid(&request.membership)?;
        validate_name(&request.name)?;
        let seed_path = self.path.with_file_name("credential-seed");
        let seed = tokio::task::spawn_blocking(move || {
            private_state::ensure_private_directory(
                seed_path.parent().context("seed has no parent")?,
            )?;
            let mut seed = [0u8; 32];
            getrandom::fill(&mut seed).expect("operating system entropy");
            private_state::create_new(&seed_path, &seed)?;
            private_state::read_bounded(&seed_path, 32)
                .map_err(|error| anyhow::anyhow!("cannot read member credential seed: {error:?}"))?
                .context("member credential seed disappeared")
        })
        .await??;
        let mut secret = [0u8; 32];
        Hkdf::<Sha256>::new(Some(b"remotecoder-cluster-v1"), &seed)
            .expand(
                format!("{}:{}", request.r#for, request.membership).as_bytes(),
                &mut secret,
            )
            .map_err(|_| anyhow::anyhow!("member credential derivation failed"))?;
        let token = format!(
            "rcp1.{}.{}.{}",
            request.r#for,
            request.membership,
            URL_SAFE_NO_PAD.encode(secret)
        );
        let hash = digest(&token);
        self.transaction(move |document| {
            ensure!(
                document
                    .records
                    .values()
                    .all(|record| record.host == request.r#for
                        || record.state == MemberState::Removed
                        || record.name != request.name),
                "member alias is already assigned"
            );
            if let Some(record) = document.records.get(&request.membership) {
                ensure!(
                    record.host == request.r#for
                        && record.state == MemberState::Active
                        && record.issued_digest == hash
                        && record.name == request.name,
                    "membership is tombstoned or belongs to a different Join"
                );
                return Ok((token, false));
            }
            ensure!(document.records.len() < 4096, "membership capacity reached");
            ensure!(
                !document
                    .records
                    .values()
                    .any(|record| record.host == request.r#for
                        && record.state != MemberState::Removed),
                "remove the previous membership before rejoining"
            );
            document.records.insert(
                request.membership.clone(),
                MemberRecord {
                    protocol: PROTOCOL,
                    host: request.r#for,
                    membership: request.membership,
                    state: MemberState::Active,
                    name: request.name,
                    routes: Vec::new(),
                    pin: String::new(),
                    issued_digest: hash,
                    credential: None,
                },
            );
            Ok((token, true))
        })
        .await
    }

    pub(crate) async fn accept(&self, request: AcceptParams) -> Result<MemberRecord> {
        ensure!(request.protocol == PROTOCOL, "unsupported cluster protocol");
        validate_uuid(&request.host)?;
        validate_uuid(&request.membership)?;
        validate_name(&request.name)?;
        ensure!(
            !request.routes.is_empty() && request.routes.len() <= 8,
            "Join requires 1–8 direct TLS routes"
        );
        for route in &request.routes {
            let url = url::Url::parse(route)?;
            ensure!(
                route.len() <= 2048
                    && url.scheme() == "wss"
                    && url.host_str().is_some()
                    && url.username().is_empty()
                    && url.password().is_none()
                    && url.path() == "/ws"
                    && url.query().is_none()
                    && url.fragment().is_none(),
                "member route must be a direct wss /ws URL"
            );
        }
        ensure!(
            base64::engine::general_purpose::STANDARD
                .decode(&request.pin)?
                .len()
                == 32,
            "invalid member TLS pin"
        );
        ensure!(
            request.credential.starts_with("rcp1.") && request.credential.len() <= 256,
            "invalid member credential"
        );
        self.transaction(move |document| {
            let record = document
                .records
                .get_mut(&request.membership)
                .context("issue the reverse membership before accepting Join")?;
            ensure!(
                record.state == MemberState::Active
                    && record.host == request.host
                    && record.name == request.name,
                "membership was removed or changed"
            );
            if record.credential.is_some() {
                ensure!(
                    record.routes == request.routes
                        && record.pin == request.pin
                        && record.credential.as_ref() == Some(&request.credential),
                    "Join retry changed its immutable inputs"
                );
                return Ok((record.clone(), false));
            }
            record.routes = request.routes;
            record.pin = request.pin;
            record.credential = Some(request.credential);
            Ok((record.clone(), true))
        })
        .await
    }

    pub(crate) async fn remove(
        &self,
        request: RemoveParams,
        pending: bool,
    ) -> Result<MemberRecord> {
        ensure!(request.protocol == PROTOCOL, "unsupported cluster protocol");
        validate_uuid(&request.host)?;
        validate_uuid(&request.membership)?;
        self.transaction(move |document| {
            let existed = document.records.contains_key(&request.membership);
            let record = document
                .records
                .entry(request.membership.clone())
                .or_insert_with(|| MemberRecord {
                    protocol: PROTOCOL,
                    host: request.host.clone(),
                    membership: request.membership,
                    state: MemberState::Removed,
                    name: request.host.clone(),
                    routes: Vec::new(),
                    pin: String::new(),
                    issued_digest: String::new(),
                    credential: None,
                });
            ensure!(
                record.host == request.host,
                "membership belongs to another host"
            );
            let state = if pending && (!existed || record.state != MemberState::Removed) {
                MemberState::RemovePending
            } else {
                MemberState::Removed
            };
            let changed = !existed
                || record.state != state
                || (state == MemberState::Removed && record.credential.is_some());
            record.state = state;
            if state == MemberState::Removed {
                record.credential = None;
            }
            Ok((record.clone(), changed))
        })
        .await
    }

    pub(crate) async fn authenticate(
        &self,
        token: &str,
    ) -> Result<Option<crate::auth::installation_credentials::Grant>> {
        let parts: Vec<_> = token.split('.').collect();
        if parts.len() != 4 || parts[0] != "rcp1" || token.len() > 256 {
            return Ok(None);
        }
        let (host, membership, hash) = (parts[1], parts[2], digest(token));
        let valid = self.validate_credential(host, membership, &hash).await?;
        Ok(
            valid.then(|| crate::auth::installation_credentials::Grant::Peer {
                host: host.to_owned(),
                membership: membership.to_owned(),
                digest: hash,
            }),
        )
    }

    pub(crate) async fn is_removed(&self, host: &str, membership: &str) -> Result<bool> {
        let snapshot = self.snapshot().await?;
        Ok(snapshot
            .document
            .records
            .get(membership)
            .is_some_and(|record| record.host == host && record.state == MemberState::Removed))
    }

    async fn credential_state(
        &self,
        host: &str,
        membership: &str,
        hash: &str,
    ) -> Result<Option<MemberState>> {
        let snapshot = self.snapshot().await?;
        Ok(snapshot
            .document
            .records
            .get(membership)
            .filter(|record| {
                record.host == host
                    && bool::from(record.issued_digest.as_bytes().ct_eq(hash.as_bytes()))
            })
            .map(|record| record.state))
    }

    pub(crate) async fn validate_credential(
        &self,
        host: &str,
        membership: &str,
        hash: &str,
    ) -> Result<bool> {
        match self.credential_state(host, membership, hash).await? {
            Some(MemberState::Active) => Ok(true),
            Some(MemberState::Removed) => Err(MembershipRemoved {
                host: host.to_owned(),
                membership: membership.to_owned(),
            }
            .into()),
            _ => Ok(false),
        }
    }

    pub(crate) async fn valid(&self, host: &str, membership: &str, hash: &str) -> Result<bool> {
        Ok(self.credential_state(host, membership, hash).await? == Some(MemberState::Active))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn removed_membership_is_terminal_and_revocation_evidence_requires_the_exact_credential()
    {
        let directory = tempfile::tempdir().unwrap();
        let members = Members::new(directory.path());
        let host = "00000000-0000-4000-8000-000000000011";
        let membership = "00000000-0000-4000-8000-000000000012";
        let issue = IssueParams {
            protocol: PROTOCOL,
            r#for: host.into(),
            name: "removed-host".into(),
            membership: membership.into(),
        };
        let token = members.issue(issue.clone()).await.unwrap();
        let request = RemoveParams {
            protocol: PROTOCOL,
            host: host.into(),
            membership: membership.into(),
        };
        assert_eq!(
            members.remove(request.clone(), true).await.unwrap().state,
            MemberState::RemovePending
        );
        assert_eq!(
            members.remove(request.clone(), false).await.unwrap().state,
            MemberState::Removed
        );
        let changes = members.changes().await;
        let record = members.remove(request, true).await.unwrap();
        assert_eq!(record.state, MemberState::Removed);
        assert!(record.credential.is_none());
        assert!(!changes.has_changed().unwrap());
        assert!(members.issue(issue).await.is_err());
        assert!(
            !members
                .valid(host, membership, &digest(&token))
                .await
                .unwrap()
        );
        let removed = members
            .authenticate(&token)
            .await
            .unwrap_err()
            .downcast::<MembershipRemoved>()
            .unwrap();
        assert_eq!(removed.host, host);
        assert_eq!(removed.membership, membership);
        assert!(
            members
                .authenticate(&format!("{token}x"))
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            !members
                .is_removed("00000000-0000-4000-8000-000000000013", membership)
                .await
                .unwrap()
        );
        assert!(
            !members
                .is_removed(host, "00000000-0000-4000-8000-000000000013")
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn cached_reads_and_failed_writes_preserve_committed_membership() {
        let directory = tempfile::tempdir().unwrap();
        let members = Members::new(directory.path());
        let mut changes = members.changes().await;
        let host = "00000000-0000-4000-8000-000000000001";
        let membership = "00000000-0000-4000-8000-000000000002";
        let request = IssueParams {
            protocol: PROTOCOL,
            r#for: host.to_owned(),
            name: "test-host".to_owned(),
            membership: membership.to_owned(),
        };
        let token = members.issue(request.clone()).await.unwrap();
        assert!(changes.has_changed().unwrap());
        changes.borrow_and_update();
        assert_eq!(members.issue(request).await.unwrap(), token);
        assert!(!changes.has_changed().unwrap());

        std::fs::remove_file(&members.path).unwrap();
        std::fs::create_dir(&members.path).unwrap();
        assert!(members.authenticate(&token).await.unwrap().is_some());
        assert!(
            members
                .valid(host, membership, &digest(&token))
                .await
                .unwrap()
        );
        assert_eq!(members.resolve(host).await.unwrap().membership, membership);
        assert_eq!(members.resolve("test-host").await.unwrap().host, host);
        assert_eq!(members.all().await.unwrap().len(), 1);
        assert!(!changes.has_changed().unwrap());

        let removal = RemoveParams {
            protocol: PROTOCOL,
            host: host.to_owned(),
            membership: membership.to_owned(),
        };
        assert!(members.remove(removal.clone(), false).await.is_err());
        assert!(members.authenticate(&token).await.unwrap().is_some());
        assert_eq!(
            members.resolve(host).await.unwrap().state,
            MemberState::Active
        );
        assert!(!changes.has_changed().unwrap());

        std::fs::remove_dir(&members.path).unwrap();
        members.remove(removal.clone(), false).await.unwrap();
        assert!(changes.has_changed().unwrap());
        changes.borrow_and_update();
        assert!(
            members
                .authenticate(&token)
                .await
                .unwrap_err()
                .is::<MembershipRemoved>()
        );
        assert!(members.resolve(host).await.is_err());
        members.remove(removal, false).await.unwrap();
        assert!(!changes.has_changed().unwrap());

        let reopened = Members::new(directory.path());
        assert!(
            reopened
                .authenticate(&token)
                .await
                .unwrap_err()
                .is::<MembershipRemoved>()
        );
        assert!(reopened.resolve("test-host").await.is_err());
        let records = reopened.all().await.unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].membership, membership);
        assert_eq!(records[0].state, MemberState::Removed);
    }
}
