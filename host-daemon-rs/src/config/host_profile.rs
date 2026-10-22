use anyhow::{Context, Result};
use serde::Deserialize;
use std::sync::OnceLock;

const HOST_PROFILES: &str = include_str!("../../config/host-profiles.json");
static PROFILES: OnceLock<Result<HostProfiles, String>> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DesktopMode {
    Shared,
    Disabled,
}

impl DesktopMode {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            DesktopMode::Shared => "shared",
            DesktopMode::Disabled => "disabled",
        }
    }

    pub(crate) fn for_this_host() -> Result<Self> {
        let host = nix::unistd::gethostname().context("failed to read this host's name")?;
        Ok(Self::for_host(load_profiles()?, &host.to_string_lossy()))
    }

    fn for_host(profiles: &HostProfiles, host: &str) -> Self {
        if lists(&profiles.hosts_without_chatgpt_desktop, host) {
            DesktopMode::Disabled
        } else {
            DesktopMode::Shared
        }
    }
}

/// The existing host profile document owns physical automation authority.
pub(crate) struct AutomationAuthority;

impl AutomationAuthority {
    pub(crate) fn for_this_host() -> Result<bool> {
        let host = nix::unistd::gethostname().context("failed to read this host's name")?;
        Ok(Self::for_host(load_profiles()?, &host.to_string_lossy()))
    }

    pub(crate) fn authority() -> Result<Option<String>> {
        Ok(load_profiles()?.automation_authority_hosts.first().cloned())
    }

    pub(crate) fn capability() -> serde_json::Value {
        match (Self::authority(), Self::for_this_host()) {
            (Ok(authority), Ok(available)) => {
                serde_json::json!({"available":available,"authority":authority})
            }
            _ => {
                serde_json::json!({"available":false,"authority":null,"reason":"configurationUnavailable"})
            }
        }
    }

    fn for_host(profiles: &HostProfiles, host: &str) -> bool {
        lists(&profiles.automation_authority_hosts, host)
    }
}

pub(crate) struct FullDiskAccessRequirement;

impl FullDiskAccessRequirement {
    pub(crate) fn for_this_host() -> Result<bool> {
        let host = nix::unistd::gethostname().context("failed to read this host's name")?;
        Ok(Self::for_host(load_profiles()?, &host.to_string_lossy()))
    }

    fn for_host(profiles: &HostProfiles, host: &str) -> bool {
        lists(&profiles.full_disk_access_hosts, host)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct HostProfiles {
    hosts_without_chatgpt_desktop: Vec<String>,
    automation_authority_hosts: Vec<String>,
    full_disk_access_hosts: Vec<String>,
}

fn lists(hosts: &[String], host: &str) -> bool {
    let short_name = host.split('.').next().unwrap_or(host);
    hosts
        .iter()
        .any(|listed| listed.eq_ignore_ascii_case(short_name))
}

pub(crate) fn validate() -> Result<()> {
    load_profiles().map(|_| ())
}

fn load_profiles() -> Result<&'static HostProfiles> {
    PROFILES
        .get_or_init(|| read_profiles().map_err(|error| format!("{error:#}")))
        .as_ref()
        .map_err(|error| anyhow::anyhow!("{error}"))
}

fn read_profiles() -> Result<HostProfiles> {
    let paths = super::HostPaths::from_env()?;
    let path = paths.state("host-profiles.json");
    let bytes = crate::storage::private_state::read_bounded(&path, 65536)
        .map_err(|error| anyhow::anyhow!("Cannot read host-profiles.json: {error:?}"))?;
    match bytes {
        Some(bytes) => {
            parse_profiles(std::str::from_utf8(&bytes).context("host-profiles.json is not UTF-8")?)
        }
        None => parse_profiles(HOST_PROFILES),
    }
}

fn parse_profiles(source: &str) -> Result<HostProfiles> {
    let profiles: HostProfiles =
        serde_json::from_str(source).context("host-profiles.json is invalid")?;
    anyhow::ensure!(
        profiles.automation_authority_hosts.len() <= 1,
        "host-profiles.json must name at most one automation authority"
    );
    for hosts in [
        &profiles.hosts_without_chatgpt_desktop,
        &profiles.automation_authority_hosts,
        &profiles.full_disk_access_hosts,
    ] {
        anyhow::ensure!(
            hosts.len() <= 32
                && hosts.iter().all(|host| !host.is_empty()
                    && host.len() <= 253
                    && host
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')),
            "host-profiles.json requires at most 32 short hostnames per policy"
        );
    }
    Ok(profiles)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracked_profiles_disable_automatic_desktop_on_both_macs() {
        let profiles = parse_profiles(r#"{"hostsWithoutChatgptDesktop":["gateway-primary","gateway-secondary"],"automationAuthorityHosts":["gateway-primary"],"fullDiskAccessHosts":["gateway-primary"]}"#).expect("tracked host profiles parse");
        assert_eq!(
            DesktopMode::for_host(&profiles, "gateway-primary"),
            DesktopMode::Disabled
        );
        assert_eq!(
            DesktopMode::for_host(&profiles, "Gateway-Primary.local"),
            DesktopMode::Disabled
        );
        assert_eq!(
            DesktopMode::for_host(&profiles, "gateway-secondary"),
            DesktopMode::Disabled
        );
        assert_eq!(
            DesktopMode::for_host(&profiles, "Gateway-Secondary.local"),
            DesktopMode::Disabled
        );
        assert_eq!(
            DesktopMode::for_host(&profiles, "gateway-primary-2"),
            DesktopMode::Shared
        );
    }

    #[test]
    fn automation_authority_requires_an_explicit_physical_host_profile() {
        let profiles = parse_profiles(r#"{"hostsWithoutChatgptDesktop":["gateway-primary","gateway-secondary"],"automationAuthorityHosts":["gateway-primary"],"fullDiskAccessHosts":["gateway-primary"]}"#).unwrap();
        for host in ["gateway-primary", "Gateway-Primary.local"] {
            assert!(AutomationAuthority::for_host(&profiles, host));
        }
        for host in ["gateway-secondary", "gateway-primary-2", "another-host"] {
            assert!(!AutomationAuthority::for_host(&profiles, host));
        }
        let relocated = parse_profiles(
            r#"{"hostsWithoutChatgptDesktop":[],"automationAuthorityHosts":["replacement-mini"],"fullDiskAccessHosts":[]}"#,
        )
        .unwrap();
        assert!(AutomationAuthority::for_host(
            &relocated,
            "replacement-mini"
        ));
        assert!(!AutomationAuthority::for_host(
            &relocated,
            "gateway-primary"
        ));
    }

    #[test]
    fn only_the_headless_mini_requires_full_disk_access() {
        let profiles = parse_profiles(r#"{"hostsWithoutChatgptDesktop":["gateway-primary","gateway-secondary"],"automationAuthorityHosts":["gateway-primary"],"fullDiskAccessHosts":["gateway-primary"]}"#).unwrap();
        for host in ["gateway-primary", "Gateway-Primary.local"] {
            assert!(FullDiskAccessRequirement::for_host(&profiles, host));
        }
        for host in ["gateway-secondary", "gateway-primary-2"] {
            assert!(!FullDiskAccessRequirement::for_host(&profiles, host));
        }
    }

    #[test]
    fn unknown_profile_fields_are_rejected() {
        assert!(parse_profiles(r#"{"hostsWithoutChatgptDesktop": [], "automationAuthorityHosts": [], "fullDiskAccessHosts": [], "desktop": "off"}"#).is_err());
    }
}
