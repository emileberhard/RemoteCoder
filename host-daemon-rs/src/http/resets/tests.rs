use super::*;
use serde_json::Value;

async fn wire(response: Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), 8192)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn reset_redemption_errors_distinguish_uncertainty_credentials_and_availability() {
    for (failure, status, code) in [
        (
            RouterError::Refused {
                status: 503,
                code: "reset_scope_insufficient".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "reset_credential_unavailable",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "reset_credential_rejected".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "reset_credential_unavailable",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "codex_credential_unavailable".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "reset_credential_unavailable",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "reset_state_unavailable".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "router_retry_later",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "account_store_unavailable".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "router_retry_later",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "upstream_unavailable".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "router_retry_later",
        ),
        (
            RouterError::Refused {
                status: 409,
                code: "redeem_in_progress".into(),
            },
            StatusCode::CONFLICT,
            "redeem_in_progress",
        ),
        (
            RouterError::Refused {
                status: 504,
                code: "redeem_unconfirmed".into(),
            },
            StatusCode::GATEWAY_TIMEOUT,
            "redeem_unconfirmed",
        ),
        (
            RouterError::RequestFailed,
            StatusCode::BAD_GATEWAY,
            "router_request_refused",
        ),
        (
            RouterError::InvalidResponse,
            StatusCode::BAD_GATEWAY,
            "router_request_refused",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "reset_credential_missing".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "reset_credential_unavailable",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "reauthorization_required".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "reset_credential_unavailable",
        ),
        (
            RouterError::Refused {
                status: 403,
                code: "insufficient_scope".into(),
            },
            StatusCode::BAD_GATEWAY,
            "router_unauthorized",
        ),
        (
            RouterError::KeyUnavailable,
            StatusCode::SERVICE_UNAVAILABLE,
            "router_key_unavailable",
        ),
        (
            RouterError::TransportUnavailable,
            StatusCode::SERVICE_UNAVAILABLE,
            "router_unavailable",
        ),
        (
            RouterError::Refused {
                status: 404,
                code: "account_not_found".into(),
            },
            StatusCode::NOT_FOUND,
            "account_not_found",
        ),
        (
            RouterError::Refused {
                status: 409,
                code: "redeem_unconfirmed_pending".into(),
            },
            StatusCode::CONFLICT,
            "redeem_unconfirmed_pending",
        ),
        (
            RouterError::Refused {
                status: 503,
                code: "router_stopping".into(),
            },
            StatusCode::SERVICE_UNAVAILABLE,
            "router_stopping",
        ),
        (
            RouterError::Refused {
                status: 504,
                code: "other_timeout".into(),
            },
            StatusCode::GATEWAY_TIMEOUT,
            "redeem_unconfirmed",
        ),
        (
            RouterError::Refused {
                status: 502,
                code: "router_request_refused".into(),
            },
            StatusCode::GATEWAY_TIMEOUT,
            "redeem_unconfirmed",
        ),
    ] {
        let response = response(Err(failure.into()));
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let value = wire(response).await;
        assert_eq!(value["error"]["code"], code);
        if code == "router_unauthorized" {
            assert!(
                value["error"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("accounts:redeem")
            );
        }
    }
}

#[tokio::test]
async fn reset_redemption_preserves_the_attempt_and_maps_all_outcomes() {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = requests.clone();
    let backend = axum::Router::new().route(
        "/accounts/resets/redeem",
        axum::routing::post(
            move |headers: axum::http::HeaderMap, Json(body): Json<Value>| {
                let recorded = recorded.clone();
                async move {
                    assert_eq!(headers[header::AUTHORIZATION], "Bearer fixture-key");
                    recorded.lock().unwrap().push(body.clone());
                    Json(json!({"outcome":body["reset_id"],"reason":"provider-value"}))
                }
            },
        ),
    );
    let (address, server) = crate::test_support::serve(backend).await;
    let router = Router::new(Some(
        crate::providers::router::RouterConfig::local_for_test(address, key),
    ))
    .unwrap();
    for (provider_outcome, app_outcome) in [
        ("reset", "reset"),
        ("already_redeemed", "alreadyRedeemed"),
        ("not_needed", "notNeeded"),
        ("refused", "refused"),
    ] {
        let result = redeem(
            &router,
            "claude",
            "first",
            provider_outcome.into(),
            "E1741C43-3D9A-4448-9F4A-3C7E5906E852"
                .to_owned()
                .try_into()
                .unwrap(),
        )
        .await;
        assert_eq!(
            wire(response(result)).await,
            json!({"outcome":app_outcome,"reason":"provider-value"})
        );
    }
    let recorded = requests.lock().unwrap();
    assert_eq!(recorded.len(), 4);
    assert_eq!(
        recorded[0],
        json!({"provider":"claude","account_id":"first","reset_id":"reset","idempotency_key":"e1741c43-3d9a-4448-9f4a-3c7e5906e852"})
    );
    server.abort();
}

#[tokio::test]
async fn reset_redemption_deadline_exceeds_the_ordinary_router_budget() {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let backend = axum::Router::new().route(
        "/accounts/resets/redeem",
        axum::routing::post(|| async {
            tokio::time::sleep(
                crate::providers::router::ROUTER_BUDGET + std::time::Duration::from_secs(1),
            )
            .await;
            Json(json!({"outcome":"reset","reason":null}))
        }),
    );
    let (address, server) = crate::test_support::serve(backend).await;
    let router = Router::new(Some(
        crate::providers::router::RouterConfig::local_for_test(address, key),
    ))
    .unwrap();
    let result = redeem(
        &router,
        "codex",
        "workspace-a",
        "offer".into(),
        "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
            .to_owned()
            .try_into()
            .unwrap(),
    )
    .await;
    assert_eq!(
        wire(response(result)).await,
        json!({"outcome":"reset","reason":null})
    );
    server.abort();
}

#[tokio::test]
async fn reset_transport_checks_error_status_before_json_and_marks_only_uncertain_submissions() {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let backend = axum::Router::new().route(
        "/accounts/resets/redeem",
        axum::routing::post(|Json(body): Json<Value>| async move {
            match body["reset_id"].as_str().unwrap() {
                "non-json-error" => (StatusCode::GATEWAY_TIMEOUT, "upstream timeout".into()),
                "unknown-error" => (
                    StatusCode::BAD_REQUEST,
                    json!({"error":{"code":"unexpected"}}).to_string(),
                ),
                "unconfirmed" => (
                    StatusCode::GATEWAY_TIMEOUT,
                    json!({"error":{"code":"redeem_unconfirmed"}}).to_string(),
                ),
                "invalid-json-success" => (StatusCode::OK, "truncated".into()),
                "invalid-shape-success" => {
                    (StatusCode::OK, json!({"outcome":"new-outcome"}).to_string())
                }
                "oversized-error" => (StatusCode::BAD_GATEWAY, "x".repeat(65 * 1024)),
                "oversized-success" => (StatusCode::OK, "x".repeat(65 * 1024)),
                _ => unreachable!(),
            }
        }),
    );
    let (address, server) = crate::test_support::serve(backend).await;
    let router = Router::new(Some(
        crate::providers::router::RouterConfig::local_for_test(address, key.clone()),
    ))
    .unwrap();
    for (id, expected) in [
        ("non-json-error", "redeem_unconfirmed"),
        ("unknown-error", "router_request_refused"),
        ("unconfirmed", "redeem_unconfirmed"),
        ("invalid-json-success", "redeem_unconfirmed"),
        ("invalid-shape-success", "redeem_unconfirmed"),
        ("oversized-error", "redeem_unconfirmed"),
        ("oversized-success", "redeem_unconfirmed"),
    ] {
        let result = redeem(
            &router,
            "codex",
            "workspace-a",
            id.into(),
            "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
                .to_owned()
                .try_into()
                .unwrap(),
        )
        .await;
        assert_eq!(
            unconfirmed(result.as_ref().err().unwrap()),
            expected == "redeem_unconfirmed"
        );
        assert_eq!(
            wire(response(result)).await["error"]["code"],
            expected,
            "{id}"
        );
    }
    server.abort();
    let router = Router::new(Some(
        crate::providers::router::RouterConfig::unreachable_for_test(key),
    ))
    .unwrap();
    let result = redeem(
        &router,
        "codex",
        "workspace-a",
        "offer".into(),
        "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
            .to_owned()
            .try_into()
            .unwrap(),
    )
    .await;
    assert_eq!(
        wire(response(result)).await["error"]["code"],
        "router_unavailable"
    );
}

#[tokio::test]
async fn reset_truncated_error_bodies_preserve_the_status_submission_contract() {
    use std::os::unix::fs::PermissionsExt;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let router = Router::new(Some(
        crate::providers::router::RouterConfig::local_for_test(listener.local_addr().unwrap(), key),
    ))
    .unwrap();
    let statuses = [400, 409, 503, 504, 500, 502, 302];
    let server = tokio::spawn(async move {
        for status in statuses {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buffer = [0; 8192];
            assert!(socket.read(&mut buffer).await.unwrap() > 0);
            socket
                .write_all(
                    format!("HTTP/1.1 {status} fixture\r\nContent-Length: 128\r\nConnection: close\r\n\r\n{{\"error\":")
                        .as_bytes(),
                )
                .await
                .unwrap();
            socket.shutdown().await.unwrap();
        }
    });
    for status in statuses {
        let result = redeem(
            &router,
            "codex",
            "workspace-a",
            "offer".into(),
            "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
                .to_owned()
                .try_into()
                .unwrap(),
        )
        .await;
        let response = response(result);
        let (gateway_status, code) = if [400, 409, 503].contains(&status) {
            (StatusCode::BAD_GATEWAY, "router_request_refused")
        } else {
            (StatusCode::GATEWAY_TIMEOUT, "redeem_unconfirmed")
        };
        assert_eq!(response.status(), gateway_status, "HTTP {status}");
        assert_eq!(wire(response).await["error"]["code"], code, "HTTP {status}");
    }
    server.await.unwrap();
}

#[tokio::test]
async fn reset_connection_loss_after_submission_is_unconfirmed_but_reads_stay_neutral() {
    use std::os::unix::fs::PermissionsExt;
    use tokio::io::AsyncReadExt;
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("key");
    std::fs::write(&key, "fixture-key").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let router = Router::new(Some(
        crate::providers::router::RouterConfig::local_for_test(listener.local_addr().unwrap(), key),
    ))
    .unwrap();
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buffer = [0; 8192];
            assert!(socket.read(&mut buffer).await.unwrap() > 0);
        }
    });
    let result = redeem(
        &router,
        "codex",
        "workspace-a",
        "offer".into(),
        "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
            .to_owned()
            .try_into()
            .unwrap(),
    )
    .await;
    assert_eq!(
        wire(response(result)).await["error"]["code"],
        "redeem_unconfirmed"
    );
    let error = router.get("accounts").await.unwrap_err();
    assert!(matches!(
        error.downcast_ref::<RouterError>(),
        Some(RouterError::RequestFailed)
    ));
    assert!(!error.to_string().contains("outcome"));
    server.await.unwrap();
}
