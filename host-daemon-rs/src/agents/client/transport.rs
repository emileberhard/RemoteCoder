use std::fmt;
use std::path::Path;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::config::GatewayEndpoint;
use crate::providers::codex::daemon::websocket_config;
use crate::wire::agent_jobs::ScopedRequest;
use crate::wire::json::{EncodedJson, encode};

pub(super) async fn scoped(path: &Path, request: &ScopedRequest) -> Result<Value, TransportError> {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

    let mut submission = Submission::NotSent;
    let result = tokio::time::timeout(REQUEST_DEADLINE, async {
        let mut encoded = serde_json::to_vec(request)?;
        anyhow::ensure!(
            encoded.len() <= crate::agents::jobs::model::MAX_JOB_BYTES as usize,
            "scoped request exceeds its byte budget"
        );
        encoded.push(b'\n');
        let mut stream = tokio::net::UnixStream::connect(path).await?;
        submission = Submission::Uncertain;
        stream.write_all(&encoded).await?;
        let mut response = Vec::new();
        BufReader::new(stream.take(crate::agents::jobs::model::MAX_JOB_BYTES + 1))
            .read_until(b'\n', &mut response)
            .await?;
        anyhow::ensure!(
            response.len() <= crate::agents::jobs::model::MAX_JOB_BYTES as usize
                && response.ends_with(b"\n"),
            "scoped route returned an incomplete or oversized response"
        );
        let response: Value = serde_json::from_slice(&response)?;
        anyhow::ensure!(
            response.get("result").is_some() ^ response.get("error").is_some(),
            "scoped route returned an invalid response"
        );
        Ok::<_, anyhow::Error>(response)
    })
    .await;
    match result {
        Ok(Ok(response)) => Ok(response),
        Ok(Err(error)) => Err(TransportError {
            submission,
            cause: format!("{error:#}"),
        }),
        Err(_) => Err(TransportError {
            submission,
            cause: "scoped route did not answer within 30 seconds".into(),
        }),
    }
}

const REQUEST_DEADLINE: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Submission {
    NotSent,
    Uncertain,
}

#[derive(Debug)]
pub(super) struct TransportError {
    pub submission: Submission,
    pub cause: String,
}

impl fmt::Display for TransportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "Agent gateway request failed: {}", self.cause)?;
        if self.submission == Submission::Uncertain {
            formatter.write_str(
                "; submission is uncertain, inspect the same request ID before retrying",
            )?;
        }
        Ok(())
    }
}

impl std::error::Error for TransportError {}

pub(super) async fn call(
    endpoint: &GatewayEndpoint,
    method: &str,
    params: Value,
) -> Result<Value, TransportError> {
    let mut submission = Submission::NotSent;
    let result = tokio::time::timeout(
        REQUEST_DEADLINE,
        exchange(endpoint, method, params, &mut submission),
    )
    .await;
    match result {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(TransportError {
            submission,
            cause: format!("{error:#}"),
        }),
        Err(_) => Err(TransportError {
            submission,
            cause: "gateway did not answer within 30 seconds".into(),
        }),
    }
}

async fn exchange(
    endpoint: &GatewayEndpoint,
    method: &str,
    params: Value,
    submission: &mut Submission,
) -> anyhow::Result<Value> {
    let request = json!({"jsonrpc":"2.0","id":1,"method":method,"params":params});
    let EncodedJson::Text(encoded) = encode(&request)? else {
        anyhow::bail!("agent request exceeds the gateway frame limit");
    };
    let url = endpoint.url("ws").replacen("http://", "ws://", 1);
    let mut request = url.into_client_request()?;
    let mut authorization = format!("Bearer {}", endpoint.bearer())
        .parse::<tokio_tungstenite::tungstenite::http::HeaderValue>()?;
    authorization.set_sensitive(true);
    request.headers_mut().insert("Authorization", authorization);
    let (mut socket, _) =
        tokio_tungstenite::connect_async_with_config(request, Some(websocket_config()), false)
            .await?;
    let ready = socket
        .next()
        .await
        .transpose()?
        .ok_or_else(|| anyhow::anyhow!("gateway closed before its readiness frame"))?;
    let Message::Text(ready) = ready else {
        anyhow::bail!("gateway sent no readiness frame");
    };
    let ready: Value = serde_json::from_str(&ready)?;
    anyhow::ensure!(
        ready["method"] == "daemon/ready",
        "gateway sent no readiness frame"
    );
    socket.send(Message::Text(json!({"id":0,"method":"initialize","params":{"clientInfo":{"name":"remotecoder-agent","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}}).to_string())).await?;
    loop {
        let frame = socket
            .next()
            .await
            .transpose()?
            .ok_or_else(|| anyhow::anyhow!("gateway closed during initialization"))?;
        match frame {
            Message::Text(text) => {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"] == 0 {
                    anyhow::ensure!(
                        response.get("result").is_some() && response.get("error").is_none(),
                        "gateway refused client initialization"
                    );
                    break;
                }
            }
            Message::Ping(bytes) => socket.send(Message::Pong(bytes)).await?,
            Message::Close(_) => anyhow::bail!("gateway closed during initialization"),
            _ => {}
        }
    }
    socket
        .send(Message::Text(json!({"method":"initialized"}).to_string()))
        .await?;
    *submission = Submission::Uncertain;
    socket.send(Message::Text(encoded)).await?;
    while let Some(frame) = socket.next().await {
        match frame? {
            Message::Text(text) => {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"] == 1 {
                    anyhow::ensure!(
                        response.get("result").is_some() ^ response.get("error").is_some(),
                        "gateway returned an invalid RPC response"
                    );
                    return Ok(response);
                }
            }
            Message::Ping(bytes) => socket.send(Message::Pong(bytes)).await?,
            Message::Close(_) => break,
            _ => {}
        }
    }
    anyhow::bail!("gateway closed before acknowledging the request")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ConfigSources;
    use std::collections::HashMap;
    use tokio::net::TcpListener;

    const TOKEN: &str = "isolated-agent-client-test-token-0123456789";

    fn endpoint(port: u16) -> GatewayEndpoint {
        GatewayEndpoint::load(&ConfigSources::from_file_vars(HashMap::from([
            ("RC_CODEX_GATEWAY_BIND_HOST".into(), "127.0.0.1".into()),
            ("RC_CODEX_GATEWAY_PORT".into(), port.to_string()),
            ("RC_CODEX_GATEWAY_AUTH_TOKEN".into(), TOKEN.into()),
        ])))
        .unwrap()
    }

    async fn initialize(socket: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) {
        let Message::Text(request) = socket.next().await.unwrap().unwrap() else {
            panic!("expected initialize");
        };
        let request: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request["method"], "initialize");
        assert_eq!(request["id"], 0);
        socket
            .send(Message::Text(json!({"id":0,"result":{}}).to_string()))
            .await
            .unwrap();
        let Message::Text(notification) = socket.next().await.unwrap().unwrap() else {
            panic!("expected initialized");
        };
        assert_eq!(
            serde_json::from_str::<Value>(&notification).unwrap()["method"],
            "initialized"
        );
    }

    #[tokio::test]
    async fn authenticated_gateway_call_preserves_structured_rpc_errors() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = endpoint(listener.local_addr().unwrap().port());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_hdr_async(
                stream,
                |request: &tokio_tungstenite::tungstenite::handshake::server::Request, response| {
                    assert_eq!(
                        request.headers()["Authorization"],
                        format!("Bearer {TOKEN}")
                    );
                    Ok(response)
                },
            )
            .await
            .unwrap();
            socket
                .send(Message::Text(json!({"method":"daemon/ready"}).to_string()))
                .await
                .unwrap();
            initialize(&mut socket).await;
            let Message::Text(request) = socket.next().await.unwrap().unwrap() else {
                panic!("expected request");
            };
            assert_eq!(
                serde_json::from_str::<Value>(&request).unwrap(),
                json!({
                    "jsonrpc":"2.0","id":1,"method":"agent/jobs/read","params":{"jobId":"job-1"}
                })
            );
            socket.send(Message::Text(json!({"id":1,"error":{"code":-32009,"message":"Conflict","data":{"kind":"conflict"}}}).to_string())).await.unwrap();
        });
        let response = call(&endpoint, "agent/jobs/read", json!({"jobId":"job-1"}))
            .await
            .unwrap();
        assert_eq!(response["error"]["data"]["kind"], "conflict");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn losing_the_receipt_never_replays_a_mutation() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = endpoint(listener.local_addr().unwrap().port());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket
                .send(Message::Text(json!({"method":"daemon/ready"}).to_string()))
                .await
                .unwrap();
            initialize(&mut socket).await;
            assert!(matches!(
                socket.next().await.unwrap().unwrap(),
                Message::Text(_)
            ));
            socket.close(None).await.unwrap();
        });
        let error = call(&endpoint, "agent/jobs/start", json!({"jobId":"job-1"}))
            .await
            .unwrap_err();
        assert_eq!(error.submission, Submission::Uncertain);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn readiness_failure_proves_the_request_was_not_sent() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = endpoint(listener.local_addr().unwrap().port());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket
                .send(Message::Text(json!({"method":"unexpected"}).to_string()))
                .await
                .unwrap();
            assert!(!matches!(socket.next().await, Some(Ok(Message::Text(_)))));
        });
        let error = call(&endpoint, "agent/jobs/start", json!({"jobId":"job-1"}))
            .await
            .unwrap_err();
        assert_eq!(error.submission, Submission::NotSent);
        server.await.unwrap();
    }
}
