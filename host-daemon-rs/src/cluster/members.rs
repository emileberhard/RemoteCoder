use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::storage::private_state::{self, ReadError};
use crate::wire::cluster::*;

const MAX_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct Members {
    path: PathBuf,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    records: BTreeMap<String, MemberRecord>,
}

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
        }
    }

    async fn transaction<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Document) -> Result<(T, bool)> + Send + 'static,
    ) -> Result<T> {
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || private_state::transaction(&path, "membership path has no parent", load, operation, |path, document| {
            ensure!(serde_json::to_vec(document)?.len() as u64 <= MAX_BYTES, "membership capacity exceeded; retained removal tombstones cannot be discarded");
            private_state::write_json(path, document)
        })).await?
    }

    pub(crate) async fn all(&self) -> Result<Vec<MemberRecord>> {
        self.transaction(|document| Ok((document.records.values().cloned().collect(), false)))
            .await
    }

    pub(crate) async fn resolve(&self, selector: &str) -> Result<MemberRecord> {
        let selector = selector.to_owned();
        self.transaction(move |document| {
            let mut records = document.records.values().filter(|record| {
                record.state != MemberState::Removed
                    && (record.host == selector || record.name == selector)
            });
            let record = records.next().context("unknown or removed member")?.clone();
            ensure!(records.next().is_none(), "member selector is ambiguous");
            Ok((record, false))
        })
        .await
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
            OsRng.fill_bytes(&mut seed);
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
            record.state = if pending {
                MemberState::RemovePending
            } else {
                MemberState::Removed
            };
            if !pending {
                record.credential = None;
            }
            Ok((record.clone(), true))
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
        let (host, membership, hash) = (parts[1].to_owned(), parts[2].to_owned(), digest(token));
        self.transaction(move |document| {
            let valid = document.records.get(&membership).is_some_and(|record| {
                record.host == host
                    && record.state == MemberState::Active
                    && bool::from(record.issued_digest.as_bytes().ct_eq(hash.as_bytes()))
            });
            Ok((
                valid.then_some(crate::auth::installation_credentials::Grant::Peer {
                    host,
                    membership,
                    digest: hash,
                }),
                false,
            ))
        })
        .await
    }

    pub(crate) async fn valid(&self, host: &str, membership: &str, hash: &str) -> Result<bool> {
        let (host, membership, hash) = (host.to_owned(), membership.to_owned(), hash.to_owned());
        self.transaction(move |document| {
            Ok((
                document.records.get(&membership).is_some_and(|record| {
                    record.host == host
                        && record.state == MemberState::Active
                        && bool::from(record.issued_digest.as_bytes().ct_eq(hash.as_bytes()))
                }),
                false,
            ))
        })
        .await
    }
}
