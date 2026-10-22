use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, header};
use axum::response::{IntoResponse, Response};
use futures_util::{Stream, StreamExt};
use tokio_util::sync::WaitForCancellationFutureOwned;
use tracing::warn;

use super::{Admitted, Ledger, Rejection, SpeechRelay, Stop};

pub(super) const MAX_REQUEST_BODY_BYTES: u64 = 64 * 1024 * 1024;

const REQUEST_BODY_IDLE_TIMEOUT: Duration = if cfg!(test) {
    Duration::from_millis(300)
} else {
    Duration::from_secs(30)
};

const FORWARDED_REQUEST_HEADERS: [HeaderName; 10] = [
    header::ACCEPT,
    header::ACCEPT_ENCODING,
    header::CONTENT_LENGTH,
    header::CONTENT_TYPE,
    HeaderName::from_static("api-revision"),
    HeaderName::from_static("x-goog-upload-command"),
    HeaderName::from_static("x-goog-upload-header-content-length"),
    HeaderName::from_static("x-goog-upload-header-content-type"),
    HeaderName::from_static("x-goog-upload-offset"),
    HeaderName::from_static("x-goog-upload-protocol"),
];

const FORWARDED_RESPONSE_HEADERS: [HeaderName; 6] = [
    header::CONTENT_ENCODING,
    header::CONTENT_LENGTH,
    header::CONTENT_TYPE,
    header::RETRY_AFTER,
    HeaderName::from_static("x-goog-upload-status"),
    GEMINI_UPLOAD_URL,
];

const GEMINI_UPLOAD_URL: HeaderName = HeaderName::from_static("x-goog-upload-url");
const GEMINI_ORIGIN: &str = "https://generativelanguage.googleapis.com";

impl SpeechRelay {
    pub(super) async fn relay_http(
        &self,
        admitted: Admitted,
        method: Method,
        headers: &HeaderMap,
        body: Body,
    ) -> Response {
        let Admitted {
            upstream,
            credential,
            mut ledger,
            relay,
            stop,
        } = admitted;
        let declared_length = headers
            .get(header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok());
        if declared_length.is_some_and(|length| length > MAX_REQUEST_BODY_BYTES) {
            ledger.reject_http(Rejection::RequestTooLarge);
            return Rejection::RequestTooLarge.into_response();
        }

        let body_failure = Arc::new(OnceLock::new());
        let mut request = self.inner.http.request(method.clone(), upstream);
        if method == Method::POST {
            request = request.body(limited_body(
                body,
                Arc::clone(&ledger.bytes_up),
                Arc::clone(&body_failure),
            ));
        }
        for name in FORWARDED_REQUEST_HEADERS {
            for value in headers.get_all(&name) {
                request = request.header(name.clone(), value.clone());
            }
        }
        request = request.header(credential.0, credential.1);

        let response = tokio::select! {
            response = request.send() => response,
            _ = relay.cancelled() => {
                let rejection = stop.reason();
                ledger.reject_http(rejection);
                return rejection.into_response();
            }
        };
        let response = match response {
            Ok(response) => response,
            Err(error) => {
                let rejection = if let Some(&rejection) = body_failure.get() {
                    rejection
                } else if error.is_connect() || error.is_timeout() {
                    Rejection::UpstreamUnreachable
                } else {
                    Rejection::UpstreamFailed
                };
                warn!(
                    provider = ledger.provider.name(),
                    operation = ledger.operation,
                    error = %error.without_url(),
                    "speech relay request failed"
                );
                ledger.reject_http(rejection);
                return rejection.into_response();
            }
        };

        ledger.status = Some(response.status().as_u16());
        let mut builder = Response::builder().status(response.status());
        for name in FORWARDED_RESPONSE_HEADERS {
            for value in response.headers().get_all(&name) {
                let value = if name == GEMINI_UPLOAD_URL {
                    gemini_upload_url(
                        value,
                        self.inner
                            .router
                            .as_ref()
                            .expect("admitted relay has a router")
                            .inference_base(),
                    )
                } else {
                    value.clone()
                };
                builder = builder.header(name.clone(), value);
            }
        }
        let body = RelayResponseBody {
            inner: Box::pin(response.bytes_stream()),
            stopped: Box::pin(relay.cancelled_owned()),
            stop,
            ledger,
            finished: false,
        };
        builder
            .body(Body::from_stream(body))
            .unwrap_or_else(|_| Rejection::UpstreamFailed.into_response())
    }
}

fn gemini_upload_url(value: &HeaderValue, router: &str) -> HeaderValue {
    value
        .to_str()
        .ok()
        .and_then(|url| url.strip_prefix(&format!("{router}/vendors/google/")))
        .and_then(|rest| HeaderValue::from_str(&format!("{GEMINI_ORIGIN}/{rest}")).ok())
        .unwrap_or_else(|| value.clone())
}

fn limited_body(
    body: Body,
    bytes_up: Arc<AtomicU64>,
    failure: Arc<OnceLock<Rejection>>,
) -> reqwest::Body {
    let state = (body.into_data_stream(), bytes_up, failure);
    reqwest::Body::wrap_stream(futures_util::stream::unfold(
        state,
        |(mut chunks, bytes_up, failure)| async move {
            let item = match tokio::time::timeout(REQUEST_BODY_IDLE_TIMEOUT, chunks.next()).await {
                Ok(None) => return None,
                Ok(Some(Err(error))) => Err(std::io::Error::other(error)),
                Ok(Some(Ok(chunk))) => {
                    let length = chunk.len() as u64;
                    if bytes_up.fetch_add(length, Ordering::Relaxed) + length
                        > MAX_REQUEST_BODY_BYTES
                    {
                        let _ = failure.set(Rejection::RequestTooLarge);
                        Err(std::io::Error::other(
                            "speech request exceeds the relay limit",
                        ))
                    } else {
                        Ok(chunk)
                    }
                }
                Err(_) => {
                    let _ = failure.set(Rejection::ClientStalled);
                    Err(std::io::Error::other(
                        "speech client stopped sending its request",
                    ))
                }
            };
            Some((item, (chunks, bytes_up, failure)))
        },
    ))
}

struct RelayResponseBody {
    inner: Pin<Box<dyn Stream<Item = reqwest::Result<Bytes>> + Send>>,
    stopped: Pin<Box<WaitForCancellationFutureOwned>>,
    stop: Arc<Stop>,
    ledger: Ledger,
    finished: bool,
}

impl Stream for RelayResponseBody {
    type Item = Result<Bytes, std::io::Error>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        if this.finished {
            return Poll::Ready(None);
        }
        if this.stopped.as_mut().poll(cx).is_ready() {
            this.finished = true;
            this.ledger.outcome = this.stop.reason().kind();
            return Poll::Ready(Some(Err(std::io::Error::other("speech relay stopped"))));
        }
        match this.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(Ok(chunk))) => {
                this.ledger.bytes_down += chunk.len() as u64;
                Poll::Ready(Some(Ok(chunk)))
            }
            Poll::Ready(Some(Err(error))) => {
                this.finished = true;
                this.ledger.outcome = Rejection::UpstreamFailed.kind();
                Poll::Ready(Some(Err(std::io::Error::other(error.without_url()))))
            }
            Poll::Ready(None) => {
                this.finished = true;
                this.ledger.outcome = "completed";
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;
    use serde_json::{Value, json};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use crate::voice::speech::SpeechClients;

    use crate::voice::speech::relay::harness::{Harness, OPERATOR, ROUTER_KEY};
    use crate::voice::speech::relay::{MAX_CONCURRENT_RELAYS, REJECTION_HEADER};

    #[tokio::test]
    async fn http_relay_injects_the_router_key_and_passes_provider_responses_through() {
        let harness = Harness::start(SpeechClients::All).await;

        let response = harness
            .post(
                "/speech/openai/v1/audio/transcriptions?key=client&language=sv&access_token=client",
                OPERATOR,
            )
            .header("x-goog-api-key", "client-supplied")
            .header("content-type", "audio/wav")
            .body("audio-bytes")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let echoed: Value = response.json().await.unwrap();
        assert_eq!(echoed["authorization"], format!("Bearer {ROUTER_KEY}"));
        assert_eq!(echoed["googleKey"], Value::Null);
        assert_eq!(echoed["contentType"], "audio/wav");
        assert_eq!(echoed["query"], "language=sv");
        assert_eq!(echoed["body"], "audio-bytes");

        let response = harness
            .post("/speech/elevenlabs/v1/speech-to-text", OPERATOR)
            .body("audio")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(response.headers()["retry-after"], "7");
        assert!(response.headers().get("x-internal-trace").is_none());
        assert!(response.headers().get(REJECTION_HEADER).is_none());
        let body: Value = response.json().await.unwrap();
        assert_eq!(body, json!({"detail": "bad audio", "key": ROUTER_KEY}));
    }

    #[tokio::test]
    async fn http_relay_streams_the_response_before_the_provider_finishes() {
        let harness = Harness::start(SpeechClients::All).await;
        let mut response = harness
            .post(
                "/speech/gemini/v1beta/models/tts:streamGenerateContent?alt=sse",
                OPERATOR,
            )
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let first = tokio::time::timeout(Duration::from_secs(5), response.chunk())
            .await
            .expect("first chunk arrived while the provider was still streaming")
            .unwrap()
            .unwrap();
        assert_eq!(&first[..], b"first");
        harness.release_stream.notify_one();
        assert_eq!(&response.chunk().await.unwrap().unwrap()[..], b"second");
        assert!(response.chunk().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn http_relay_frees_the_slot_of_a_client_that_stops_sending() {
        let harness = Harness::start(SpeechClients::All).await;
        let transcription = "/speech/openai/v1/audio/transcriptions";

        let paced =
            futures_util::stream::iter(["slow ", "but ", "live"]).then(|chunk| async move {
                tokio::time::sleep(REQUEST_BODY_IDLE_TIMEOUT / 2).await;
                Ok::<_, std::io::Error>(Bytes::from_static(chunk.as_bytes()))
            });
        let response = harness
            .post(transcription, OPERATOR)
            .body(reqwest::Body::wrap_stream(paced))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let echoed: Value = response.json().await.unwrap();
        assert_eq!(echoed["body"], "slow but live");

        let (stall, chunks) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(1);
        stall
            .send(Ok(Bytes::from_static(b"partial")))
            .await
            .unwrap();
        let stalled = futures_util::stream::unfold(chunks, |mut chunks| async move {
            chunks.recv().await.map(|chunk| (chunk, chunks))
        });
        let request = tokio::spawn(
            harness
                .post(transcription, OPERATOR)
                .body(reqwest::Body::wrap_stream(stalled))
                .send(),
        );
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS - 1).await;
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS).await;
        drop(stall);
        request.abort();
    }

    #[tokio::test]
    async fn gemini_upload_urls_name_the_provider_so_speechkit_relays_the_upload() {
        let harness = Harness::start(SpeechClients::All).await;
        let response = harness
            .post("/speech/gemini/upload/v1beta/files", OPERATOR)
            .header("x-goog-upload-protocol", "resumable")
            .header("x-goog-upload-command", "start")
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()["x-goog-upload-url"],
            "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=synthetic"
        );
    }

    #[tokio::test]
    async fn a_streamed_body_without_a_length_is_refused_at_the_limit() {
        let harness = Harness::start(SpeechClients::All).await;
        let (mut response, mut request) = tokio::net::TcpStream::connect(harness.address)
            .await
            .unwrap()
            .into_split();
        let upload = tokio::spawn(async move {
            request
                .write_all(
                    format!(
                        "POST /speech/gemini/upload/v1beta/files HTTP/1.1\r\nhost: relay\r\nauthorization: Bearer {OPERATOR}\r\ntransfer-encoding: chunked\r\n\r\n"
                    )
                    .as_bytes(),
                )
                .await?;
            let chunk = 1024 * 1024;
            let mut framed = format!("{chunk:x}\r\n").into_bytes();
            framed.resize(framed.len() + chunk, 0);
            framed.extend_from_slice(b"\r\n");
            for _ in 0..=MAX_REQUEST_BODY_BYTES / chunk as u64 {
                request.write_all(&framed).await?;
            }
            request.write_all(b"0\r\n\r\n").await
        });

        let mut head = Vec::new();
        tokio::time::timeout(Duration::from_secs(20), async {
            let mut buffer = [0u8; 1024];
            while !head.windows(4).any(|window| window == b"\r\n\r\n") {
                let read = response.read(&mut buffer).await.unwrap();
                assert!(read > 0, "the relay closed before responding");
                head.extend_from_slice(&buffer[..read]);
            }
        })
        .await
        .expect("the relay answered the oversized upload");
        upload.abort();
        let head = String::from_utf8_lossy(&head).to_ascii_lowercase();
        assert!(head.starts_with("http/1.1 413"), "{head}");
        assert!(
            head.contains("x-speech-relay-rejection: requesttoolarge"),
            "{head}"
        );
        harness.wait_for_free_slots(MAX_CONCURRENT_RELAYS).await;
    }
}
