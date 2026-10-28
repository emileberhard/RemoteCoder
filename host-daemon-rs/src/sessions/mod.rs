pub(crate) mod changes;
pub(crate) mod cluster;
pub(crate) mod ingest;
pub(crate) mod mirror;
pub(crate) mod query;
pub(crate) mod store;
pub(crate) mod worker;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub(crate) const SCHEMA_VERSION: u32 = 1;
pub(crate) const PAGE_BYTES: usize = 8 << 20;
pub(crate) const PAGE_ROWS: usize = 10_000;
pub(crate) const PROJECTION_BYTES: u64 = 32 << 30;
pub(crate) const CHANGE_DAYS: i64 = 30;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Origin {
    pub host: String,
    pub provider: String,
    pub provider_home: PathBuf,
    pub local_home: PathBuf,
}

impl Origin {
    pub fn path(&self) -> PathBuf {
        self.local_home.join(if self.provider == "codex" {
            "sessions"
        } else {
            "projects"
        })
    }

    pub fn original(&self, path: &Path) -> Result<PathBuf> {
        Ok(self
            .provider_home
            .join(path.strip_prefix(&self.local_home)?))
    }

    pub fn local(&self, path: &Path) -> Result<PathBuf> {
        let relative = path.strip_prefix(&self.provider_home)?;
        ensure!(
            relative
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_))),
            "Dependency path leaves the provider home"
        );
        Ok(self.local_home.join(relative))
    }
}

pub(crate) fn session_key(origin: &Origin, id: &str) -> String {
    let scope = blake3::hash(origin.provider_home.to_string_lossy().as_bytes()).to_hex();
    format!("{}:{}:{}:{id}", origin.host, origin.provider, &scope[..16])
}

pub(crate) fn default_database() -> Result<PathBuf> {
    Ok(crate::config::HostPaths::from_env()?.state("sessions/v1/catalog.sqlite3"))
}

fn canonical_timestamp(date: ::time::OffsetDateTime) -> String {
    let date = date.to_offset(::time::UtcOffset::UTC);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:09}Z",
        date.year(),
        u8::from(date.month()),
        date.day(),
        date.hour(),
        date.minute(),
        date.second(),
        date.nanosecond()
    )
}

pub(crate) fn now() -> String {
    canonical_timestamp(::time::OffsetDateTime::now_utc())
}

pub(crate) fn timestamp(value: &str) -> Result<String> {
    let date =
        ::time::OffsetDateTime::parse(value, &::time::format_description::well_known::Rfc3339)
            .context("Expected an RFC3339 timestamp")?;
    Ok(canonical_timestamp(date))
}

#[cfg(test)]
mod tests;
