use super::types::{AccountSnapshot, AccountState, Identity, UsageWindow};
use crate::time::unix_seconds;
use anyhow::{Result, ensure};
use serde_json::Value;
use sha2::{Digest, Sha256};

const LAST_KNOWN_USAGE_SECONDS: f64 = 1800.0;

pub(crate) fn is_last_known(observed_at: Option<f64>, now: f64) -> bool {
    observed_at.is_some_and(|at| now - at <= LAST_KNOWN_USAGE_SECONDS)
}

pub(crate) fn codex_identity_in_workspace(account: &Value, workspace: &str) -> Option<Identity> {
    let account = account.get("account")?;
    if account["type"] != "chatgpt" {
        return None;
    }
    let email = account["email"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .map(str::to_lowercase);
    let workspace = (!workspace.trim().is_empty()).then(|| workspace.to_owned());
    // Neither an email alone nor a workspace shared by several members proves identity.
    let email_key = email.as_deref()?;
    let workspace_key = workspace.as_deref()?;
    let key = format!(
        "codex:{:x}",
        Sha256::digest(format!("{email_key}\0{workspace_key}").as_bytes())
    );
    Some(Identity {
        key,
        email,
        workspace,
    })
}

pub(crate) fn apply_codex(
    snapshot: &mut AccountSnapshot,
    account: &Value,
    limits: Option<&Value>,
) -> Result<()> {
    let authenticated = account["account"]["type"] == "chatgpt";
    snapshot.plan = account["account"]["planType"].as_str().map(str::to_owned);
    snapshot.state = if authenticated {
        AccountState::Ready
    } else {
        AccountState::AuthenticationRequired
    };
    snapshot.resets = None;
    snapshot.windows.clear();
    snapshot.stale = limits.is_none();
    if !authenticated {
        snapshot.observed_at = None;
        return Ok(());
    }
    if let Some(limits) = limits {
        if let Some(buckets) = limits["rateLimitsByLimitId"]
            .as_object()
            .filter(|b| !b.is_empty())
        {
            for (key, bucket) in buckets {
                codex_windows(&mut snapshot.windows, key, bucket)?;
            }
        } else if let Some(bucket) = limits.get("rateLimits") {
            codex_windows(&mut snapshot.windows, "codex", bucket)?;
        }
        snapshot.observed_at = Some(unix_seconds());
    }
    Ok(())
}

pub(crate) fn retain_codex_usage(
    snapshot: &mut AccountSnapshot,
    previous: &AccountSnapshot,
    now: f64,
) {
    if snapshot.identity.is_some()
        && previous.identity == snapshot.identity
        && previous.generation == snapshot.generation
        && is_last_known(previous.observed_at, now)
    {
        snapshot.windows = previous.windows.clone();
        snapshot.resets = previous.resets.clone();
        snapshot.observed_at = previous.observed_at;
    }
}

fn codex_windows(windows: &mut Vec<UsageWindow>, bucket_id: &str, bucket: &Value) -> Result<()> {
    for slot in ["primary", "secondary"] {
        let window = &bucket[slot];
        let Some(percent) = window["usedPercent"].as_f64() else {
            continue;
        };
        ensure!(
            percent.is_finite() && (0.0..=100.0).contains(&percent),
            "Invalid native quota percentage"
        );
        let duration = window["windowDurationMins"].as_i64();
        let label = match duration {
            Some(300) => "Five hours".into(),
            Some(10080) => "Weekly".into(),
            Some(n) => format!("{n} minutes"),
            None => "Reported allowance".into(),
        };
        let label = if bucket_id == "codex" {
            label
        } else {
            format!(
                "{} · {label}",
                bucket["limitName"].as_str().unwrap_or(bucket_id)
            )
        };
        windows.push(UsageWindow {
            id: format!("{bucket_id}:{slot}"),
            label,
            duration_minutes: duration,
            used_percent: percent,
            resets_at: window["resetsAt"].as_f64(),
            model: if bucket_id == "codex" {
                None
            } else {
                Some(bucket_id.to_owned())
            },
        });
    }
    Ok(())
}

pub(crate) fn apply_claude(snapshot: &mut AccountSnapshot, status: &Value) -> Result<()> {
    snapshot.identity = None;
    snapshot.plan = None;
    snapshot.active_turns = status["activeTurns"].as_u64().unwrap_or(0) as usize;
    snapshot.state = if status["ok"] == true {
        AccountState::Ready
    } else {
        AccountState::Unavailable
    };
    snapshot.windows.clear();
    snapshot.resets = None;
    snapshot.observed_at = None;
    snapshot.stale = true;
    snapshot.error = if snapshot.state == AccountState::Ready {
        None
    } else {
        status["error"].as_str().map(str::to_owned)
    };
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn claude_readiness_carries_the_router_error_without_usage() {
        let mut snapshot = AccountSnapshot::pending(&super::super::types::Enrollment {
            id: "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
                .to_owned()
                .try_into()
                .unwrap(),
            provider: crate::providers::Provider::Claude,
            label: "Claude".into(),
            enabled: true,
            generation: 1,
            identity: None,
            voice_account_id: None,
            router_account_id: None,
        });
        let error = "RC_CODEX_GATEWAY_ROUTER_KEY_FILE must be one llm-router key in a regular file owned by the gateway user with mode 0600";
        apply_claude(
            &mut snapshot,
            &json!({"ok":false,"error":error,"activeTurns":0}),
        )
        .unwrap();
        assert_eq!(snapshot.state, AccountState::Unavailable);
        assert_eq!(snapshot.error.as_deref(), Some(error));
        assert!(snapshot.windows.is_empty());
        assert!(snapshot.observed_at.is_none());
        apply_claude(
            &mut snapshot,
            &json!({"ok":true,"error":null,"activeTurns":0}),
        )
        .unwrap();
        assert_eq!(snapshot.state, AccountState::Ready);
        assert!(snapshot.error.is_none());
    }

    #[test]
    fn a_failed_quota_read_keeps_only_the_same_verified_accounts_recent_usage() {
        let entry = super::super::types::Enrollment::unbound(
            "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
                .to_owned()
                .try_into()
                .unwrap(),
            "A",
        );
        let account =
            json!({"account":{"type":"chatgpt","email":"a@example.test","planType":"pro"}});
        let mut previous = AccountSnapshot::pending(&entry);
        apply_codex(
            &mut previous,
            &account,
            Some(&json!({"accountId":"workspace-a","rateLimits":{"primary":{"usedPercent":66,"windowDurationMins":10080}}})),
        )
        .unwrap();
        previous.identity = codex_identity_in_workspace(&account, "workspace-a");
        let observed = previous.observed_at.unwrap();
        let failed_read = |workspace: &str, generation: u64, now: f64| {
            let mut sample = AccountSnapshot::pending(&entry);
            sample.generation = generation;
            apply_codex(&mut sample, &account, None).unwrap();
            sample.identity = codex_identity_in_workspace(&account, workspace);
            retain_codex_usage(&mut sample, &previous, now);
            sample
        };

        let recent = failed_read("workspace-a", 1, observed + 60.0);
        assert!(recent.stale);
        assert_eq!(recent.observed_at, Some(observed));
        assert_eq!(recent.windows.len(), 1);
        assert_eq!(recent.windows[0].used_percent, 66.0);

        for sample in [
            failed_read("workspace-a", 1, observed + LAST_KNOWN_USAGE_SECONDS + 1.0),
            failed_read("workspace-b", 1, observed + 60.0),
            failed_read("workspace-a", 2, observed + 60.0),
        ] {
            assert!(sample.windows.is_empty());
            assert!(sample.observed_at.is_none());
        }
    }

    #[test]
    fn codex_quota_duration_not_slot_defines_label() {
        let mut windows = Vec::new();
        codex_windows(
            &mut windows,
            "codex",
            &json!({"primary":{"usedPercent":78,"windowDurationMins":10080},"secondary":null}),
        )
        .unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Weekly");
        assert!(windows[0].resets_at.is_none());
    }
    #[test]
    fn codex_identity_needs_email_and_workspace_and_never_api_auth() {
        let a = json!({"account":{"type":"chatgpt","email":"a@example.test"}});
        let b = json!({"account":{"type":"chatgpt","email":"b@example.test"}});
        assert_ne!(
            codex_identity_in_workspace(&a, "shared-workspace")
                .unwrap()
                .key,
            codex_identity_in_workspace(&b, "shared-workspace")
                .unwrap()
                .key
        );
        assert!(codex_identity_in_workspace(&a, "").is_none());
        assert!(
            codex_identity_in_workspace(&json!({"account":{"type":"apiKey"}}), "shared-workspace")
                .is_none()
        );
    }
}
