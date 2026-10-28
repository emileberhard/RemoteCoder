mod relay;
mod routes;

use std::collections::BTreeSet;

use anyhow::{Result, ensure};

pub(crate) use relay::SpeechRelay;

use crate::auth::installation_credentials::{Grant, valid_id as valid_installation_id};

pub(crate) const SPEECH_CLIENTS_ENV_KEY: &str = "RC_CODEX_GATEWAY_SPEECH_CLIENTS";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SpeechClients {
    All,
    Installations(BTreeSet<String>),
}

impl SpeechClients {
    pub(crate) fn parse(value: Option<&str>) -> Result<Self> {
        let Some(value) = value.map(str::trim) else {
            return Ok(Self::All);
        };
        ensure!(
            !value.is_empty(),
            "{SPEECH_CLIENTS_ENV_KEY} is set but empty; set it to `all`, to comma-separated installation IDs, or remove it to admit every client"
        );
        if value == "all" {
            return Ok(Self::All);
        }
        let mut installations = BTreeSet::new();
        for id in value.split(',').map(str::trim) {
            ensure!(
                valid_installation_id(id),
                "{SPEECH_CLIENTS_ENV_KEY} must be `all` or comma-separated installation IDs"
            );
            installations.insert(id.to_owned());
        }
        Ok(Self::Installations(installations))
    }

    fn permits(&self, grant: &Grant) -> bool {
        match (self, grant) {
            (_, Grant::Operator | Grant::Peer { .. }) | (Self::All, _) => true,
            (Self::Installations(ids), Grant::Installation { id, .. }) => ids.contains(id),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installation(id: &str) -> Grant {
        Grant::Installation {
            id: id.to_owned(),
            digest: String::new(),
        }
    }

    #[test]
    fn unset_policy_admits_every_client_and_a_list_admits_only_its_installations() {
        for value in [None, Some(" all ")] {
            let policy = SpeechClients::parse(value).unwrap();
            assert!(policy.permits(&installation("phone")));
        }
        for value in [Some(""), Some("  ")] {
            let error = SpeechClients::parse(value).unwrap_err().to_string();
            assert!(error.contains("is set but empty"), "{error}");
        }

        let policy = SpeechClients::parse(Some("phone, ipad")).unwrap();
        assert!(policy.permits(&installation("ipad")));
        assert!(!policy.permits(&installation("laptop")));
        assert!(policy.permits(&Grant::Operator));

        assert!(SpeechClients::parse(Some("phone,,ipad")).is_err());
        assert!(SpeechClients::parse(Some("none of these")).is_err());
    }
}
