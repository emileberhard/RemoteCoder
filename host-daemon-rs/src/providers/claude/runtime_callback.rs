use serde_json::Value;
use std::{path::Path, time::Duration};

pub(super) async fn post(
    mcp_config: &Path,
    path: &str,
    body: &Value,
    timeout: Duration,
) -> Option<Value> {
    let data = tokio::fs::read(mcp_config).await.ok()?;
    let config: Value = serde_json::from_slice(&data).ok()?;
    let server = &config["mcpServers"][crate::agents::tools::NAMESPACE];
    let mut url = reqwest::Url::parse(server["url"].as_str()?).ok()?;
    if url.host_str() != Some("127.0.0.1") {
        return None;
    }
    url.set_path(path);
    reqwest::Client::builder()
        .no_proxy()
        .timeout(timeout)
        .build()
        .ok()?
        .post(url)
        .header(
            "Authorization",
            server["headers"]["Authorization"].as_str()?,
        )
        .json(body)
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()
}
