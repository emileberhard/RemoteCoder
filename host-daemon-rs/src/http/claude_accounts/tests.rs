use super::*;
use crate::providers::router::{Router, RouterConfig};
use std::os::unix::fs::PermissionsExt;

fn payload() -> Value {
    json!({"accounts":[
        {"id":"first","provider":"claude","label":"First","plan":"max","shared":false,"credential":"rejected",
         "availability":"rejected","available_at":"2026-10-06T10:00:00Z",
         "usage":{"observed_at":"2026-10-06T07:00:00Z",
                  "five_hour":{"utilization":1.2,"resets_at":"2026-10-06T10:00:00Z"},
                  "weekly":{"utilization":0.55,"resets_at":"2026-10-09T16:00:00Z"}}},
        {"id":"ca4d1cbc-865c-4136-a13c-bd004f229c93","provider":"codex","label":"codex@example.test","plan":"pro",
         "shared":false,"credential":"invalid","availability":"unavailable","available_at":null,"usage":null},
        {"id":"second","provider":"claude","label":"Second","plan":"pro","shared":true,"credential":"ready",
         "availability":"available","available_at":null,"usage":null}
    ],"claude":{"automatic":"second","preference":"first"},"codex":{"inventory":"ok"}})
}
#[test]
fn maps_claude_accounts_without_inventing_missing_observations() {
    let observed = 1791270000.0;
    let directory = map_directory(payload()).unwrap();
    assert_eq!(directory.automatic, "second");
    assert_eq!(directory.preference.as_deref(), Some("first"));
    assert_eq!(directory.accounts.len(), 2);
    let account = &directory.accounts[0];
    assert_eq!(account.plan, "max");
    assert_eq!(account.available_at, Some(1791280800.0));
    assert_eq!(account.observed_at, Some(observed));
    assert_eq!(account.windows.len(), 2);
    assert_eq!(account.windows[0].used_percent, 100.0);
    assert_eq!(account.windows[0].duration_minutes, Some(300));
    assert_eq!(account.windows[0].resets_at, Some(1791280800.0));
    assert!((account.windows[1].used_percent - 55.0).abs() < 1e-10);
    assert_eq!(account.windows[1].id, "weekly");
    assert_eq!(account.windows[1].duration_minutes, Some(10080));
    assert_eq!(account.windows[1].resets_at, Some(1791561600.0));
    assert!(directory.accounts[1].shared);
    assert!(directory.accounts[1].windows.is_empty());
    assert!(directory.accounts[1].observed_at.is_none());
    let mut invalid = payload();
    invalid["accounts"][0]["usage"]["five_hour"]["utilization"] = json!(-0.1);
    assert!(map_directory(invalid).is_err());
    for (field, value) in [
        ("automatic", json!("absent")),
        ("preference", json!("ca4d1cbc-865c-4136-a13c-bd004f229c93")),
    ] {
        let mut invalid = payload();
        invalid["claude"][field] = value;
        assert!(map_directory(invalid).is_err());
    }
    let mut automatic = payload();
    automatic["claude"]["preference"] = Value::Null;
    assert!(map_directory(automatic).unwrap().preference.is_none());
}
#[tokio::test]
async fn private_router_authenticates_and_preserves_actionable_refusals() {
    async fn backend(headers: axum::http::HeaderMap) -> Response {
        assert_eq!(headers[header::AUTHORIZATION], "Bearer fixture-key");
        Json(payload()).into_response()
    }
    async fn refused(Json(body): Json<Value>) -> Response {
        assert_eq!(body, json!({"provider":"claude","account":"absent"}));
        (
            StatusCode::NOT_FOUND,
            Json(json!({"error":{"code":"account_not_found"}})),
        )
            .into_response()
    }
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = axum::Router::new()
        .route("/accounts", axum::routing::get(backend))
        .route("/accounts/preference", axum::routing::put(refused));
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let router = Router::new(Some(RouterConfig::local_for_test(address, key.clone()))).unwrap();
    let result = response(router.get("accounts").await);
    assert_eq!(result.status(), StatusCode::OK);
    assert_eq!(result.headers()[header::CACHE_CONTROL], "no-store");
    let result = response(
        router
            .put(
                "accounts/preference",
                json!({"provider":"claude","account":"absent"}),
            )
            .await,
    );
    assert_eq!(result.status(), StatusCode::NOT_FOUND);
    let bytes = axum::body::to_bytes(result.into_body(), 4096)
        .await
        .unwrap();
    let error: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(error["error"]["code"], "account_not_found");
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o644)).unwrap();
    let result = response(router.get("accounts").await);
    assert_eq!(result.status(), StatusCode::SERVICE_UNAVAILABLE);
    let bytes = axum::body::to_bytes(result.into_body(), 4096)
        .await
        .unwrap();
    let error: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(error["error"]["code"], "router_key_unavailable");
    server.abort();
}

#[test]
fn claude_resets_map_dates_nullable_details_and_unavailable_observations() {
    let mut inventory = payload();
    inventory["accounts"][0]["resets"] = json!({
        "state":"known","observed_at":"2026-10-06T07:00:00Z","available":3,
        "offers":[{"id":"grant","title":"Full reset","remaining":3,
            "expires_at":"2026-10-09T16:00:00Z","usable_now":false,
            "requires_limit":true,"clears":["five_hour","seven_day"]}],"error":null
    });
    inventory["accounts"][2]["resets"] = json!({
        "state":"unavailable","observed_at":null,"available":null,"offers":null,
        "error":{"code":"reauthorization_required"}
    });
    let wire = serde_json::to_value(map_directory(inventory.clone()).unwrap()).unwrap();
    assert_eq!(
        wire["accounts"][0]["resets"],
        json!({
            "state":"known","observedAt":1791270000.0,"available":3,
            "offers":[{"id":"grant","title":"Full reset","remaining":3,
                "expiresAt":1791561600.0,"usableNow":false,"requiresLimit":true,
                "clears":["five_hour","seven_day"]}],"error":null
        })
    );
    assert_eq!(
        wire["accounts"][1]["resets"],
        json!({
            "state":"unavailable","observedAt":null,"available":null,"offers":null,
            "error":"reauthorization_required"
        })
    );
    for details in [Value::Null, json!([])] {
        inventory["accounts"][0]["resets"]["offers"] = details.clone();
        let wire = serde_json::to_value(map_directory(inventory.clone()).unwrap()).unwrap();
        assert_eq!(wire["accounts"][0]["resets"]["offers"], details);
        assert_eq!(wire["accounts"][0]["resets"]["available"], 3);
    }
    inventory["accounts"][0]["resets"] = Value::Null;
    assert!(
        map_directory(inventory).unwrap().accounts[0]
            .resets
            .is_none()
    );
}

#[test]
fn malformed_resets_degrade_only_the_affected_claude_observation() {
    for malformed in [
        json!({"state":"unexpected"}),
        json!({"state":"known","available":-1}),
        json!({"state":"known","offers":[{"id":"offer","remaining":1,"expires_at":"invalid"}]}),
        json!({"state":"unavailable","available":0,"error":{"code":"upstream_unavailable"}}),
    ] {
        let mut inventory = payload();
        inventory["accounts"][0]["resets"] = malformed;
        inventory["accounts"][2]["resets"] =
            json!({"state":"known","available":0,"offers":[],"error":null});
        let wire = serde_json::to_value(map_directory(inventory).unwrap()).unwrap();
        assert_eq!(wire["accounts"][0]["windows"].as_array().unwrap().len(), 2);
        assert_eq!(
            wire["accounts"][0]["resets"],
            json!({"state":"unavailable","available":null,"offers":null,"observedAt":null,"error":"upstream_unavailable"})
        );
        assert_eq!(wire["accounts"][1]["resets"]["available"], 0);
        assert_eq!(wire["accounts"][1]["resets"]["offers"], json!([]));
    }
}
