use std::borrow::Cow;
use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::extract::Request;
use axum::extract::ws::{CloseFrame, Message, WebSocketUpgrade};
use axum::http::{HeaderMap, HeaderValue, StatusCode, Uri, header};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio_tungstenite::tungstenite;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::auth::installation_credentials::{Enrollment, InstallationCredentials};
use crate::observability::journal::Journal;
use crate::providers::router::RouterConfig;
use crate::voice::speech::SpeechClients;

use super::{REJECTION_HEADER, SpeechRelay};
use crate::voice::speech::relay::websocket::UpstreamSocket;

pub(super) const OPERATOR: &str = "synthetic-operator-credential";
pub(super) const ROUTER_KEY: &str = "synthetic-router-key";

pub(super) struct Harness {
    pub(super) relay: SpeechRelay,
    pub(super) address: std::net::SocketAddr,
    pub(super) installations: InstallationCredentials,
    pub(super) release_stream: Arc<Notify>,
    pub(super) http: reqwest::Client,
    pub(super) _directory: tempfile::TempDir,
}

impl Harness {
    pub(super) async fn start(clients: SpeechClients) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let key_file = directory.path().join("router-key");
        std::fs::write(&key_file, ROUTER_KEY).unwrap();
        std::fs::set_permissions(&key_file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let installations = InstallationCredentials::new(
            directory.path().join("installations.json"),
            Arc::new(crate::cluster::members::Members::new(directory.path())),
        );
        let release_stream = Arc::new(Notify::new());
        let router = serve(mock_router(Arc::clone(&release_stream))).await;
        let relay = SpeechRelay::new(
            OPERATOR.to_owned(),
            installations.clone(),
            Some(RouterConfig::local_for_test(router, key_file)),
            clients,
            Journal::disabled(),
        )
        .unwrap();
        let address = serve(relay.router()).await;
        Self {
            relay,
            address,
            installations,
            release_stream,
            http: reqwest::Client::new(),
            _directory: directory,
        }
    }

    pub(super) async fn enroll(&self, id: &str) -> String {
        self.installations
            .enroll(
                Enrollment {
                    installation_id: id.to_owned(),
                    label: id.to_owned(),
                },
                OPERATOR,
            )
            .await
            .unwrap()
    }

    pub(super) fn post(&self, path: &str, token: &str) -> reqwest::RequestBuilder {
        self.http
            .post(format!("http://{}{path}", self.address))
            .bearer_auth(token)
    }

    pub(super) async fn socket(
        &self,
        path: &str,
        token: &str,
    ) -> Result<UpstreamSocket, (StatusCode, String)> {
        let mut request = format!("ws://{}{path}", self.address)
            .into_client_request()
            .unwrap();
        request.headers_mut().insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        match tokio_tungstenite::connect_async(request).await {
            Ok((socket, _)) => Ok(socket),
            Err(tungstenite::Error::Http(response)) => {
                let kind = response
                    .headers()
                    .get(REJECTION_HEADER)
                    .expect("relay refusals carry the rejection marker")
                    .to_str()
                    .unwrap()
                    .to_owned();
                Err((response.status(), kind))
            }
            Err(error) => panic!("relay handshake failed outside HTTP: {error}"),
        }
    }

    pub(super) async fn wait_for_free_slots(&self, expected: usize) {
        let capacity = &self.relay.inner.capacity;
        tokio::time::timeout(Duration::from_secs(5), async {
            while capacity.available_permits() != expected {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap_or_else(|_| {
            panic!(
                "expected {expected} free relay slots, found {}",
                capacity.available_permits()
            )
        });
    }
}

async fn serve(router: Router) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    address
}

fn header_text(headers: &HeaderMap, name: &str) -> Value {
    headers
        .get(name)
        .map(|value| Value::from(value.to_str().unwrap()))
        .unwrap_or(Value::Null)
}

fn mock_router(release_stream: Arc<Notify>) -> Router {
    Router::new()
        .route(
            "/vendors/openai/v1/audio/transcriptions",
            post(|request: Request| async move {
                let (parts, body) = request.into_parts();
                let body = axum::body::to_bytes(body, 1024).await.unwrap();
                Json(json!({
                    "authorization": header_text(&parts.headers, "authorization"),
                    "googleKey": header_text(&parts.headers, "x-goog-api-key"),
                    "contentType": header_text(&parts.headers, "content-type"),
                    "query": parts.uri.query(),
                    "body": String::from_utf8(body.to_vec()).unwrap(),
                }))
            }),
        )
        .route(
            "/vendors/elevenlabs/v1/speech-to-text",
            post(|headers: HeaderMap| async move {
                (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    [
                        ("retry-after", "7"),
                        ("x-internal-trace", "upstream-only"),
                        ("x-speech-relay-rejection", "spoofed"),
                    ],
                    Json(
                        json!({"detail": "bad audio", "key": header_text(&headers, "xi-api-key")}),
                    ),
                )
            }),
        )
        .route(
            "/vendors/google/v1beta/models/:model",
            post(move || {
                let release_stream = Arc::clone(&release_stream);
                async move {
                    let first = futures_util::stream::iter([Ok::<_, std::io::Error>(
                        Bytes::from_static(b"first"),
                    )]);
                    let second = futures_util::stream::once(async move {
                        release_stream.notified().await;
                        Ok(Bytes::from_static(b"second"))
                    });
                    Body::from_stream(first.chain(second))
                }
            }),
        )
        .route(
            "/vendors/google/upload/v1beta/files",
            post(|headers: HeaderMap, body: Body| async move {
                let mut body = body.into_data_stream();
                while let Some(Ok(_)) = body.next().await {}
                let host = headers[header::HOST].to_str().unwrap().to_owned();
                (
                    StatusCode::OK,
                    [(
                        "x-goog-upload-url",
                        format!(
                            "http://{host}/vendors/google/upload/v1beta/files?upload_id=synthetic"
                        ),
                    )],
                )
            }),
        )
        .route(
            "/vendors/openai/v1/realtime",
            get(
                |upgrade: WebSocketUpgrade, headers: HeaderMap, uri: Uri| async move {
                    upgrade.on_upgrade(move |mut socket| async move {
                        match uri.query() {
                            Some("behavior=drop") => return,
                            Some("behavior=flood") => {
                                let chunk = vec![0u8; 1024 * 1024];
                                while socket.send(Message::Binary(chunk.clone())).await.is_ok() {}
                                return;
                            }
                            _ => {}
                        }
                        let hello = json!({
                            "authorization": header_text(&headers, "authorization"),
                            "query": uri.query(),
                        });
                        if socket.send(Message::Text(hello.to_string())).await.is_err() {
                            return;
                        }
                        while let Some(Ok(message)) = socket.recv().await {
                            let reply = match message {
                                Message::Text(text) if text == "bye" => {
                                    Message::Close(Some(CloseFrame {
                                        code: 4321,
                                        reason: Cow::Borrowed("upstream-bye"),
                                    }))
                                }
                                Message::Text(_) | Message::Binary(_) => message,
                                _ => continue,
                            };
                            let closing = matches!(reply, Message::Close(_));
                            if socket.send(reply).await.is_err() || closing {
                                return;
                            }
                        }
                    })
                },
            ),
        )
}

pub(super) async fn rejection_kind(response: reqwest::Response) -> (u16, String) {
    let status = response.status().as_u16();
    let kind = response
        .headers()
        .get(REJECTION_HEADER)
        .expect("relay refusals carry the rejection marker")
        .to_str()
        .unwrap()
        .to_owned();
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["remoteCoderSpeechError"]["kind"], kind.as_str());
    (status, kind)
}

pub(super) async fn next_frame(socket: &mut UpstreamSocket) -> tungstenite::Message {
    tokio::time::timeout(Duration::from_secs(5), socket.next())
        .await
        .expect("relay delivered a frame in time")
        .expect("relay kept the socket open")
        .expect("relay frame was valid")
}

pub(super) async fn next_message(socket: &mut UpstreamSocket) -> tungstenite::Message {
    loop {
        let frame = next_frame(socket).await;
        if !matches!(
            frame,
            tungstenite::Message::Ping(_) | tungstenite::Message::Pong(_)
        ) {
            return frame;
        }
    }
}

pub(super) async fn next_close(socket: &mut UpstreamSocket) -> (u16, String) {
    loop {
        if let tungstenite::Message::Close(Some(frame)) = next_message(socket).await {
            return (frame.code.into(), frame.reason.into_owned());
        }
    }
}
