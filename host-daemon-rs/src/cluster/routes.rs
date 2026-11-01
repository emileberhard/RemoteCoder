use anyhow::{Context, Result, ensure};
use std::collections::HashMap;

pub(crate) const ENV_KEY: &str = "RC_CODEX_GATEWAY_CLUSTER_ROUTES";

pub(crate) fn parse(value: Option<&str>) -> Result<HashMap<String, String>> {
    let Some(value) = value else {
        return Ok(HashMap::new());
    };
    ensure!(value.len() <= 2 * 1024 * 1024, "{ENV_KEY} exceeds 2 MiB");
    let routes: HashMap<String, String> = serde_json::from_str(value).with_context(|| {
        format!("{ENV_KEY} must map exact host UUIDs to one direct wss /ws route each")
    })?;
    ensure!(routes.len() <= 4096, "{ENV_KEY} exceeds 4096 hosts");
    for (host, route) in &routes {
        super::members::validate_uuid(host)?;
        super::members::validate_route(route)?;
    }
    Ok(routes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cluster_routes_require_exact_hosts_and_pinned_transport_urls() {
        assert!(parse(None).unwrap().is_empty());
        let host = "11111111-1111-4111-8111-111111111111";
        let route = "wss://host.example.ts.net:8789/ws";
        assert_eq!(
            parse(Some(&serde_json::json!({host:route}).to_string())).unwrap()[host],
            route
        );
        for value in [
            serde_json::json!({"alias":route}),
            serde_json::json!({host:"ws://host/ws"}),
            serde_json::json!({host:"wss://user:password@host/ws"}),
            serde_json::json!({host:[route]}),
        ] {
            assert!(parse(Some(&value.to_string())).is_err());
        }
    }
}
