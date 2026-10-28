pub(crate) mod changes;
pub(crate) mod cluster;
mod discovery;
mod hot;
pub(crate) mod ingest;
pub(crate) mod mirror;
pub(crate) mod query;
pub(crate) mod storage;
pub(crate) mod store;
pub(crate) mod worker;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub(crate) const SCHEMA_VERSION: u32 = 3;
pub(crate) const PAGE_BYTES: usize = 8 << 20;
pub(crate) const PAGE_ROWS: usize = 10_000;
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

    pub fn is_transcript(&self, path: &Path) -> bool {
        if path
            .extension()
            .is_none_or(|extension| extension != "jsonl")
        {
            return false;
        }
        if self.provider == "codex" {
            return path.starts_with(self.path());
        }
        let Ok(relative) = path.strip_prefix(self.path()) else {
            return false;
        };
        let mut parts = relative.iter();
        if parts.next().is_none() || parts.next().is_none() {
            return false;
        }
        match parts.next() {
            None => true,
            Some(directory) => {
                directory == "subagents"
                    && path
                        .file_stem()
                        .is_some_and(|name| name.as_encoded_bytes().starts_with(b"agent-"))
            }
        }
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

pub(crate) fn error_data(error: &anyhow::Error) -> serde_json::Value {
    let message = format!("{error:#}");
    let (class, kind) = if message.starts_with("cursor_expired:") {
        ("conflict", "cursor_expired")
    } else if message.starts_with("source_changed:") || message.starts_with("conflict:") {
        ("conflict", "source_changed")
    } else if message.starts_with("source deleted") || message.starts_with("not_found:") {
        ("not_found", "not_found")
    } else if message.starts_with("unsupported:") {
        ("unsupported", "unsupported")
    } else if message.starts_with("refused:") {
        ("refused", "refused")
    } else if message.starts_with("unavailable:") {
        ("unavailable", "unavailable")
    } else if message.starts_with("capacity:") || message.starts_with("stale: budget") {
        ("refused", "capacity")
    } else if let Some(io) = error.downcast_ref::<std::io::Error>() {
        if io.kind() == std::io::ErrorKind::NotFound {
            ("not_found", "not_found")
        } else {
            ("unavailable", "unavailable")
        }
    } else if let Some(rusqlite::Error::SqliteFailure(code, _)) =
        error.downcast_ref::<rusqlite::Error>()
    {
        match code.extended_code & 255 {
            rusqlite::ffi::SQLITE_BUSY | rusqlite::ffi::SQLITE_LOCKED => {
                ("unavailable", "unavailable")
            }
            rusqlite::ffi::SQLITE_READONLY
            | rusqlite::ffi::SQLITE_AUTH
            | rusqlite::ffi::SQLITE_PERM => ("refused", "refused"),
            rusqlite::ffi::SQLITE_INTERRUPT
            | rusqlite::ffi::SQLITE_TOOBIG
            | rusqlite::ffi::SQLITE_FULL
            | rusqlite::ffi::SQLITE_NOMEM => ("refused", "capacity"),
            _ => ("usage", "usage"),
        }
    } else {
        ("usage", "usage")
    };
    serde_json::json!({"class":class,"kind":kind,"message":message,"retryable":class=="unavailable"})
}

pub(crate) fn exit_code(data: &serde_json::Value) -> i32 {
    match data["class"].as_str() {
        Some("not_found") => 3,
        Some("refused") => 4,
        Some("unavailable") => 5,
        Some("uncertain") => 6,
        Some("unsupported") => 7,
        Some("conflict") => 8,
        _ => 2,
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod idle_measurement;
