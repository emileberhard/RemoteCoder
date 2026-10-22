use std::fmt;

use serde::Serialize;

#[cfg(test)]
mod inputs;

#[derive(Serialize)]
pub(crate) struct BuildIdentity {
    pub(crate) version: &'static str,
    pub(crate) commit: Option<&'static str>,
    pub(crate) modified: Option<bool>,
    #[serde(rename = "workerHash")]
    pub(crate) worker_hash: &'static str,
}

include!(concat!(env!("OUT_DIR"), "/gateway_identity.rs"));

impl fmt::Display for BuildIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let version = if self.version == "dev" {
            "Dev"
        } else {
            self.version
        };
        write!(formatter, "{version}")?;
        if let Some(commit) = self.commit {
            write!(formatter, " · {}", &commit[..8])?;
        }
        if self.modified == Some(true) {
            write!(formatter, " (modified)")?;
        }
        Ok(())
    }
}
