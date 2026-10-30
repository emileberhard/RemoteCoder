use std::time::Duration;

use anyhow::Result;
use axum::Json;
use axum::body::Body;
use axum::extract::rejection::QueryRejection;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::json;
use tracing::{info, warn};

use crate::files::upload::{
    Append, Declaration, StoredUpload, UploadError, UploadId, UploadStatus,
};
use crate::files::{DownloadError, DownloadRequest};

use super::HttpState;
use super::auth::{Authorized, header_value};

const UPLOAD_SHA256_HEADER: &str = "x-remotecoder-sha256";
const UPLOAD_OFFSET_HEADER: &str = "x-remotecoder-upload-offset";
const UPLOAD_LENGTH_HEADER: &str = "x-remotecoder-upload-length";

#[derive(Deserialize)]
pub(super) struct UploadQuery {
    /// The original file name, percent-encoded by the client. A query
    /// parameter rather than a header because header values cannot carry the
    /// non-ASCII names real files have.
    name: String,
}

/// Appends one request's body to the upload its id names, starting it at
/// offset 0. Bearer-authed exactly like `/health` and `/ws`.
///
/// The body is streamed straight to disk, so the size ceiling is enforced
/// here against the declared lengths and inside the store while reading, not
/// by `DefaultBodyLimit`, which only bounds buffered extractors.
pub(super) async fn append_upload(
    State(state): State<HttpState>,
    _: Authorized,
    Path(raw_id): Path<String>,
    query: Result<Query<UploadQuery>, QueryRejection>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let Some(id) = UploadId::parse(&raw_id) else {
        return upload_failed(&state, &raw_id, "", &UploadError::InvalidId);
    };
    let Ok(Query(query)) = query else {
        return upload_failed(&state, id.as_str(), "", &UploadError::InvalidName);
    };
    let number = |name: &str| header_value(&headers, name).parse::<u64>().ok();
    let (Some(content_length), Some(offset), Some(length)) = (
        number(header::CONTENT_LENGTH.as_str()),
        number(UPLOAD_OFFSET_HEADER),
        number(UPLOAD_LENGTH_HEADER),
    ) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "Content-Length, X-RemoteCoder-Upload-Offset and X-RemoteCoder-Upload-Length are required"
            })),
        )
            .into_response();
    };
    let declaration = Declaration {
        name: &query.name,
        length,
        sha256: header_value(&headers, UPLOAD_SHA256_HEADER),
    };
    let append = Append {
        offset,
        content_length,
    };
    match state
        .uploads
        .append(&id, declaration, append, body.into_data_stream())
        .await
    {
        Ok(stored) => {
            state.journal.upload(
                "stored",
                json!({
                    "id": id.as_str(),
                    "name": query.name,
                    "path": stored.path,
                    "bytes": stored.bytes,
                }),
            );
            (StatusCode::CREATED, Json(receipt(&stored))).into_response()
        }
        Err(error) => upload_failed(&state, id.as_str(), &query.name, &error),
    }
}

/// How far the upload got: `offset` is where the next append starts, and a
/// finished upload adds its `file`. An id nothing arrived under is at 0.
pub(super) async fn upload_status(
    State(state): State<HttpState>,
    _: Authorized,
    Path(raw_id): Path<String>,
) -> Response {
    let Some(id) = UploadId::parse(&raw_id) else {
        return upload_failed(&state, &raw_id, "", &UploadError::InvalidId);
    };
    match state.uploads.status(&id) {
        Ok(UploadStatus::Absent) => Json(json!({ "offset": 0 })).into_response(),
        Ok(UploadStatus::Incomplete { offset }) => {
            Json(json!({ "offset": offset })).into_response()
        }
        Ok(UploadStatus::Stored(stored)) => {
            Json(json!({ "offset": stored.bytes, "file": receipt(&stored) })).into_response()
        }
        Err(error) => upload_failed(&state, id.as_str(), "", &error),
    }
}

/// Stores one whole body from an app that predates resumable uploads as a
/// single attempt at a fresh upload, discarded unless it is stored.
pub(super) async fn legacy_upload(
    State(state): State<HttpState>,
    authorized: Authorized,
    query: Result<Query<UploadQuery>, QueryRejection>,
    mut headers: HeaderMap,
    body: Body,
) -> Response {
    let id = UploadId::random();
    headers.insert(
        HeaderName::from_static(UPLOAD_OFFSET_HEADER),
        HeaderValue::from_static("0"),
    );
    if let Some(length) = headers.get(header::CONTENT_LENGTH).cloned() {
        headers.insert(HeaderName::from_static(UPLOAD_LENGTH_HEADER), length);
    }
    let response = append_upload(
        State(state.clone()),
        authorized,
        Path(id.as_str().to_owned()),
        query,
        headers,
        body,
    )
    .await;
    if response.status() != StatusCode::CREATED {
        let _ = state.uploads.discard(&id).await;
    }
    response
}

/// Removes an unfinished upload the client gave up on.
pub(super) async fn discard_upload(
    State(state): State<HttpState>,
    _: Authorized,
    Path(raw_id): Path<String>,
) -> Response {
    let Some(id) = UploadId::parse(&raw_id) else {
        return upload_failed(&state, &raw_id, "", &UploadError::InvalidId);
    };
    match state.uploads.discard(&id).await {
        Ok(()) => {
            state
                .journal
                .upload("discarded", json!({ "id": id.as_str() }));
            StatusCode::NO_CONTENT.into_response()
        }
        Err(error) => upload_failed(&state, id.as_str(), "", &error),
    }
}

fn receipt(stored: &StoredUpload) -> serde_json::Value {
    json!({
        "path": stored.path,
        "bytes": stored.bytes,
        "sha256": stored.sha256,
    })
}

pub(super) async fn download_file(
    State(state): State<HttpState>,
    _: Authorized,
    body: Body,
) -> Response {
    if state.gateway.is_draining() {
        return DownloadError::Draining.into_response();
    }
    let bytes =
        match tokio::time::timeout(Duration::from_secs(30), axum::body::to_bytes(body, 8192)).await
        {
            Ok(Ok(bytes)) => bytes,
            _ => return DownloadError::InvalidPath.into_response(),
        };
    let request = match serde_json::from_slice::<DownloadRequest>(&bytes) {
        Ok(request) => request,
        Err(_) => return DownloadError::InvalidPath.into_response(),
    };
    match state.files.download(request).await {
        Ok(response) => response,
        Err(error) => error.into_response(),
    }
}

/// Answers an append that kept its bytes but ended early as `paused`, so the
/// client continues later, and any other failure as `rejected`.
fn upload_failed(state: &HttpState, id: &str, name: &str, error: &UploadError) -> Response {
    let (status, paused) = match error {
        UploadError::InvalidId
        | UploadError::InvalidName
        | UploadError::InvalidHash
        | UploadError::DeclarationMismatch
        | UploadError::LengthMismatch { .. }
        | UploadError::HashMismatch => (StatusCode::BAD_REQUEST, false),
        UploadError::InvalidLength => (StatusCode::PAYLOAD_TOO_LARGE, false),
        UploadError::OffsetMismatch { .. } | UploadError::AlreadyStored => {
            (StatusCode::CONFLICT, false)
        }
        UploadError::Discarded => (StatusCode::GONE, false),
        UploadError::InsufficientStorage => (StatusCode::INSUFFICIENT_STORAGE, false),
        UploadError::TooManyIncomplete => (StatusCode::TOO_MANY_REQUESTS, false),
        UploadError::Busy => (StatusCode::SERVICE_UNAVAILABLE, false),
        UploadError::Io(_) => (StatusCode::INTERNAL_SERVER_ERROR, false),
        UploadError::Draining => (StatusCode::SERVICE_UNAVAILABLE, true),
        UploadError::Stalled => (StatusCode::REQUEST_TIMEOUT, true),
        UploadError::Superseded => (StatusCode::CONFLICT, true),
        UploadError::Interrupted(_) => (StatusCode::REQUEST_TIMEOUT, true),
    };
    let reason = error.message();
    if paused {
        let offset = UploadId::parse(id).and_then(|id| match state.uploads.status(&id) {
            Ok(UploadStatus::Incomplete { offset }) => Some(offset),
            _ => None,
        });
        info!(id, %reason, ?offset, "paused upload");
        state.journal.upload(
            "paused",
            json!({ "id": id, "offset": offset, "reason": reason }),
        );
    } else {
        warn!(id, name, %reason, "rejected upload");
        state.journal.upload(
            "rejected",
            json!({ "id": id, "name": name, "reason": reason }),
        );
    }
    (status, Json(json!({ "error": reason }))).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    use crate::auth::installation_credentials::InstallationCredentials;

    use crate::http::server::harness::{HOST, LanHarness, OPERATOR, exchange};

    #[tokio::test]
    async fn file_download_route_authenticates_before_reading_and_honors_revocation() {
        let lan = LanHarness::start().await;
        let path = lan.directory.path().join("original å:12.bin");
        let bytes = b"\0original binary\xff";
        std::fs::write(&path, bytes).unwrap();
        let request = serde_json::to_vec(&json!({"path": path})).unwrap();
        let installations = InstallationCredentials::new(
            lan.directory.path().join("installation-credentials.json"),
            lan.gateway.cluster_link().await.unwrap().store.clone(),
        );
        let installation_id = "file-test-phone";
        let token = installations
            .enroll(
                crate::auth::installation_credentials::Enrollment {
                    installation_id: installation_id.to_string(),
                    label: "File download test".to_string(),
                },
                OPERATOR,
            )
            .await
            .unwrap();
        for (credential, expected) in [("wrong", 401), (OPERATOR, 200), (token.as_str(), 200)] {
            let mut stream = lan.connect(&lan.pin).await.unwrap();
            let (status, body) = exchange(
                &mut stream,
                &format!(
                    "POST /files/download HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {credential}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                    request.len(),
                ),
                &request,
            ).await;
            assert_eq!(status, expected);
            if expected == 200 {
                assert_eq!(body, bytes);
            } else {
                assert_eq!(
                    serde_json::from_slice::<Value>(&body).unwrap(),
                    json!({"error": "unauthorized"})
                );
            }
        }

        installations
            .revoke(installation_id.to_string())
            .await
            .unwrap();
        std::fs::remove_file(&path).unwrap();
        for (credential, expected, kind) in [
            (token.as_str(), 401, None),
            (OPERATOR, 404, Some("missing")),
        ] {
            let mut stream = lan.connect(&lan.pin).await.unwrap();
            let (status, body) = exchange(
                &mut stream,
                &format!(
                    "POST /files/download HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {credential}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                    request.len(),
                ),
                &request,
            ).await;
            assert_eq!(status, expected);
            if let Some(kind) = kind {
                let error = serde_json::from_slice::<Value>(&body).unwrap();
                assert_eq!(error["kind"], kind);
                assert!(!error["message"].as_str().unwrap().is_empty());
            }
        }
        lan.stop().await;
    }

    #[tokio::test]
    async fn legacy_upload_route_stores_a_whole_body_and_discards_a_failed_one() {
        let lan = LanHarness::start().await;
        let bytes = b"sent by an app before resumable uploads";
        let valid = crate::ids::sha256_hex(bytes);
        let wrong = "0".repeat(64);
        let mut stored = None;
        for (digest, expected) in [(valid.as_str(), 201), (wrong.as_str(), 400)] {
            let mut stream = lan.connect(&lan.pin).await.unwrap();
            let (status, body) = exchange(
                &mut stream,
                &format!(
                    "POST /uploads?name=notes.txt HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {OPERATOR}\r\nX-RemoteCoder-SHA256: {digest}\r\nContent-Length: {}\r\n\r\n",
                    bytes.len(),
                ),
                bytes,
            )
            .await;
            assert_eq!(status, expected);
            if expected == 201 {
                stored = Some(serde_json::from_slice::<Value>(&body).unwrap());
            }
        }
        let stored = stored.unwrap();
        assert_eq!(stored["sha256"], valid);
        assert_eq!(
            std::fs::read(stored["path"].as_str().unwrap()).unwrap(),
            bytes
        );
        let uploads = std::fs::read_dir(lan.directory.path().join("uploads"))
            .unwrap()
            .count();
        assert_eq!(uploads, 1);
        lan.stop().await;
    }

    #[tokio::test]
    async fn file_download_route_rejects_malformed_and_oversized_requests() {
        let lan = LanHarness::start().await;
        for request in [
            b"not json".to_vec(),
            vec![b' '; 8193],
            br#"{"path":"relative.txt"}"#.to_vec(),
        ] {
            let mut stream = lan.connect(&lan.pin).await.unwrap();
            let (status, body) = exchange(
                &mut stream,
                &format!(
                    "POST /files/download HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer {OPERATOR}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                    request.len(),
                ),
                &request,
            ).await;
            assert_eq!(status, 400);
            assert_eq!(
                serde_json::from_slice::<Value>(&body).unwrap()["kind"],
                "invalidPath"
            );
        }
        lan.stop().await;
    }
}
