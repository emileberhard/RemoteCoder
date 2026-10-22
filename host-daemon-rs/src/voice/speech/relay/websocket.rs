use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use axum::http::{HeaderName, HeaderValue};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use reqwest::Url;
use tokio::net::TcpStream;
use tokio::sync::Notify;
use tokio::time::MissedTickBehavior;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite};
use tokio_util::sync::CancellationToken;

use crate::providers::codex::daemon::websocket_config;

use super::{Admitted, CONNECT_TIMEOUT, Ledger, Rejection, Stop};

const CLIENT_PING_INTERVAL: Duration = if cfg!(test) {
    Duration::from_millis(200)
} else {
    Duration::from_secs(15)
};

const CLIENT_PONG_DEADLINE: Duration = if cfg!(test) {
    Duration::from_secs(2)
} else {
    Duration::from_secs(30)
};

const CLOSE_GRACE: Duration = Duration::from_secs(1);

pub(super) type UpstreamSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub(super) struct ConnectedSocket {
    upstream: UpstreamSocket,
    ledger: Ledger,
    relay: CancellationToken,
    stop: Arc<Stop>,
}

enum SocketEnd {
    Stopped,
    ClientClosed(Option<CloseFrame<'static>>),
    UpstreamClosed(Option<tungstenite::protocol::CloseFrame<'static>>),
    UpstreamFailed,
}

pub(super) async fn connect_socket(admitted: Admitted) -> Result<ConnectedSocket, Rejection> {
    let Admitted {
        upstream,
        credential,
        mut ledger,
        relay,
        stop,
    } = admitted;
    let connected = tokio::select! {
        connected = connect_upstream(upstream, credential) => connected,
        _ = relay.cancelled() => Err((stop.reason(), None)),
    };
    match connected {
        Ok(upstream) => Ok(ConnectedSocket {
            upstream,
            ledger,
            relay,
            stop,
        }),
        Err((rejection, upstream_status)) => {
            ledger.reject_upgrade(rejection, upstream_status);
            Err(rejection)
        }
    }
}

async fn connect_upstream(
    url: Url,
    credential: (HeaderName, HeaderValue),
) -> Result<UpstreamSocket, (Rejection, Option<u16>)> {
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(|_| (Rejection::CredentialsUnavailable, None))?;
    request.headers_mut().insert(credential.0, credential.1);
    match tokio::time::timeout(
        CONNECT_TIMEOUT,
        tokio_tungstenite::connect_async_with_config(request, Some(websocket_config()), true),
    )
    .await
    {
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(tungstenite::Error::Http(response))) => Err((
            Rejection::UpstreamRejected,
            Some(response.status().as_u16()),
        )),
        Ok(Err(_)) | Err(_) => Err((Rejection::UpstreamUnreachable, None)),
    }
}

pub(super) async fn relay_socket(client: WebSocket, connected: ConnectedSocket) {
    let ConnectedSocket {
        upstream,
        mut ledger,
        relay,
        stop,
    } = connected;
    let (mut client_tx, mut client_rx) = client.split();
    let (mut upstream_tx, mut upstream_rx) = upstream.split();
    let pong = Notify::new();
    let end = {
        let bytes_up = &ledger.bytes_up;
        let bytes_down = &mut ledger.bytes_down;
        tokio::select! {
            _ = relay.cancelled() => SocketEnd::Stopped,
            end = client_to_upstream(&mut client_rx, &mut upstream_tx, bytes_up, &pong) => end,
            end = upstream_to_client(&mut upstream_rx, &mut client_tx, bytes_down) => end,
            () = client_liveness(&pong) => SocketEnd::ClientClosed(None),
        }
    };

    let (to_client, to_upstream) = match end {
        SocketEnd::Stopped => {
            let rejection = stop.reason();
            ledger.close(rejection.kind(), Some(rejection.close_code()));
            (
                Some(rejection.close_message()),
                Some(tungstenite::Message::Close(None)),
            )
        }
        SocketEnd::ClientClosed(frame) => {
            ledger.close("clientClosed", frame.as_ref().map(|frame| frame.code));
            let frame = frame.map(|frame| tungstenite::protocol::CloseFrame {
                code: frame.code.into(),
                reason: frame.reason,
            });
            (None, Some(tungstenite::Message::Close(frame)))
        }
        SocketEnd::UpstreamClosed(frame) => {
            ledger.close(
                "completed",
                frame.as_ref().map(|frame| u16::from(frame.code)),
            );
            let frame = frame.map(|frame| CloseFrame {
                code: frame.code.into(),
                reason: frame.reason,
            });
            (Some(Message::Close(frame)), None)
        }
        SocketEnd::UpstreamFailed => {
            let rejection = Rejection::UpstreamFailed;
            ledger.close(rejection.kind(), Some(rejection.close_code()));
            (Some(rejection.close_message()), None)
        }
    };
    let _ = tokio::time::timeout(CLOSE_GRACE, async {
        tokio::join!(
            async {
                if let Some(message) = to_client {
                    let _ = client_tx.send(message).await;
                }
            },
            async {
                if let Some(message) = to_upstream {
                    let _ = upstream_tx.send(message).await;
                }
            },
        )
    })
    .await;
}

async fn client_to_upstream(
    client: &mut SplitStream<WebSocket>,
    upstream: &mut SplitSink<UpstreamSocket, tungstenite::Message>,
    bytes_up: &AtomicU64,
    pong: &Notify,
) -> SocketEnd {
    loop {
        let forwarded = match client.next().await {
            Some(Ok(Message::Text(text))) => tungstenite::Message::Text(text),
            Some(Ok(Message::Binary(data))) => tungstenite::Message::Binary(data),
            Some(Ok(Message::Pong(_))) => {
                pong.notify_one();
                continue;
            }
            Some(Ok(Message::Ping(_))) => continue,
            Some(Ok(Message::Close(frame))) => return SocketEnd::ClientClosed(frame),
            Some(Err(_)) | None => return SocketEnd::ClientClosed(None),
        };
        bytes_up.fetch_add(forwarded.len() as u64, Ordering::Relaxed);
        if upstream.send(forwarded).await.is_err() {
            return SocketEnd::UpstreamFailed;
        }
    }
}

async fn upstream_to_client(
    upstream: &mut SplitStream<UpstreamSocket>,
    client: &mut SplitSink<WebSocket, Message>,
    bytes_down: &mut u64,
) -> SocketEnd {
    let mut ping = tokio::time::interval_at(
        tokio::time::Instant::now() + CLIENT_PING_INTERVAL,
        CLIENT_PING_INTERVAL,
    );
    ping.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        let forwarded = tokio::select! {
            _ = ping.tick() => Message::Ping(Vec::new()),
            message = upstream.next() => match message {
                Some(Ok(tungstenite::Message::Text(text))) => {
                    *bytes_down += text.len() as u64;
                    Message::Text(text)
                }
                Some(Ok(tungstenite::Message::Binary(data))) => {
                    *bytes_down += data.len() as u64;
                    Message::Binary(data)
                }
                Some(Ok(
                    tungstenite::Message::Ping(_)
                    | tungstenite::Message::Pong(_)
                    | tungstenite::Message::Frame(_),
                )) => continue,
                Some(Ok(tungstenite::Message::Close(frame))) => {
                    return SocketEnd::UpstreamClosed(frame);
                }
                Some(Err(_)) | None => return SocketEnd::UpstreamFailed,
            },
        };
        if client.send(forwarded).await.is_err() {
            return SocketEnd::ClientClosed(None);
        }
    }
}

async fn client_liveness(pong: &Notify) {
    while tokio::time::timeout(CLIENT_PONG_DEADLINE, pong.notified())
        .await
        .is_ok()
    {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;
    use serde_json::Value;

    use crate::voice::speech::SpeechClients;

    use crate::voice::speech::relay::harness::{
        Harness, OPERATOR, ROUTER_KEY, next_close, next_frame, next_message,
    };
    use crate::voice::speech::relay::{DRAIN_GRACE, MAX_CONCURRENT_RELAYS};

    #[tokio::test]
    async fn websocket_relay_pumps_frames_and_forwards_the_provider_close() {
        let harness = Harness::start(SpeechClients::All).await;
        let mut socket = harness
            .socket(
                "/speech/openai/v1/realtime?model=gpt-realtime&key=client",
                OPERATOR,
            )
            .await
            .unwrap();

        let tungstenite::Message::Text(hello) = next_message(&mut socket).await else {
            panic!("expected the upstream greeting");
        };
        let hello: Value = serde_json::from_str(&hello).unwrap();
        assert_eq!(hello["authorization"], format!("Bearer {ROUTER_KEY}"));
        assert_eq!(hello["query"], "model=gpt-realtime");

        socket
            .send(tungstenite::Message::Text("audio-event".into()))
            .await
            .unwrap();
        assert_eq!(
            next_message(&mut socket).await,
            tungstenite::Message::Text("audio-event".into())
        );
        socket
            .send(tungstenite::Message::Binary(vec![1, 2, 3]))
            .await
            .unwrap();
        assert_eq!(
            next_message(&mut socket).await,
            tungstenite::Message::Binary(vec![1, 2, 3])
        );
        socket
            .send(tungstenite::Message::Text("bye".into()))
            .await
            .unwrap();
        assert_eq!(
            next_close(&mut socket).await,
            (4321, "upstream-bye".to_owned())
        );
    }

    #[tokio::test]
    async fn websocket_refusals_are_marked_http_responses_before_the_upgrade() {
        let harness = Harness::start(SpeechClients::All).await;

        assert_eq!(
            harness
                .socket("/speech/openai/v1/realtime", "not-a-credential")
                .await
                .err(),
            Some((StatusCode::UNAUTHORIZED, "unauthorized".to_owned()))
        );
        assert_eq!(
            harness
                .socket(
                    "/speech/gemini/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                    OPERATOR,
                )
                .await
                .err(),
            Some((StatusCode::BAD_GATEWAY, "upstreamRejected".to_owned()))
        );
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS).await;
    }

    #[tokio::test]
    async fn the_relay_pings_clients_and_frees_the_slot_of_one_that_stops_answering() {
        let harness = Harness::start(SpeechClients::All).await;
        let realtime = "/speech/openai/v1/realtime";
        let mut responsive = harness.socket(realtime, OPERATOR).await.unwrap();
        next_message(&mut responsive).await;
        let _unresponsive = harness.socket(realtime, OPERATOR).await.unwrap();

        let listening_until = tokio::time::Instant::now() + CLIENT_PONG_DEADLINE * 2;
        let mut pings = 0;
        while let Ok(frame) =
            tokio::time::timeout_at(listening_until, next_frame(&mut responsive)).await
        {
            assert!(
                matches!(frame, tungstenite::Message::Ping(_)),
                "unexpected frame {frame:?}"
            );
            pings += 1;
        }
        assert!(pings >= 2, "the relay sent only {pings} pings");
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS - 1).await;

        responsive
            .send(tungstenite::Message::Text("still here".into()))
            .await
            .unwrap();
        assert_eq!(
            next_message(&mut responsive).await,
            tungstenite::Message::Text("still here".into())
        );
    }

    #[tokio::test]
    async fn drain_stops_a_relay_whose_client_writes_are_blocked() {
        let harness = Harness::start(SpeechClients::All).await;
        let _stalled = harness
            .socket("/speech/openai/v1/realtime?behavior=flood", OPERATOR)
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(500)).await;

        let started = tokio::time::Instant::now();
        harness.relay.drain().await;
        assert!(started.elapsed() < DRAIN_GRACE);
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS).await;
    }
}
