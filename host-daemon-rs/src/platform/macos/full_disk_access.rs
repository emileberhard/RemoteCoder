use serde::Serialize;
use std::path::Path;
use std::time::Duration;

const PROBE_LIMIT: Duration = Duration::from_secs(5);
pub(crate) const SYSTEM_TCC_DATABASE: &str = "/Library/Application Support/com.apple.TCC/TCC.db";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum FullDiskAccess {
    Granted,
    Denied,
    Unknown,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FullDiskAccessReport {
    pub(crate) required: bool,
    pub(crate) state: FullDiskAccess,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) detail: Option<String>,
}

pub(crate) async fn probe(database: &Path, required: bool) -> FullDiskAccessReport {
    let database = database.to_owned();
    let opened = tokio::task::spawn_blocking(move || std::fs::File::open(database).map(drop));
    let (state, detail) = match tokio::time::timeout(PROBE_LIMIT, opened).await {
        Ok(Ok(Ok(()))) => (FullDiskAccess::Granted, None),
        Ok(Ok(Err(error))) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            (FullDiskAccess::Denied, None)
        }
        Ok(Ok(Err(error))) => (FullDiskAccess::Unknown, Some(error.to_string())),
        Ok(Err(error)) => (FullDiskAccess::Unknown, Some(error.to_string())),
        Err(_) => (
            FullDiskAccess::Unknown,
            Some(format!(
                "the probe did not finish within {} s; an unanswered macOS privacy prompt blocks protected file access",
                PROBE_LIMIT.as_secs()
            )),
        ),
    };
    FullDiskAccessReport {
        required,
        state,
        detail,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_readable_database_is_granted_and_a_missing_one_is_unknown() {
        let home = tempfile::tempdir().unwrap();
        let database = home.path().join("TCC.db");
        let missing = probe(&database, true).await;
        assert_eq!(missing.state, FullDiskAccess::Unknown);
        assert!(missing.detail.is_some());
        std::fs::write(&database, b"").unwrap();
        let granted = probe(&database, false).await;
        assert_eq!(granted.state, FullDiskAccess::Granted);
        assert_eq!(
            serde_json::to_value(&granted).unwrap(),
            serde_json::json!({"required": false, "state": "granted"})
        );
    }

    #[tokio::test]
    async fn an_unreadable_database_is_denied() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let database = home.path().join("TCC.db");
        std::fs::write(&database, b"").unwrap();
        std::fs::set_permissions(&database, std::fs::Permissions::from_mode(0o000)).unwrap();
        assert_eq!(probe(&database, true).await.state, FullDiskAccess::Denied);
    }
}
