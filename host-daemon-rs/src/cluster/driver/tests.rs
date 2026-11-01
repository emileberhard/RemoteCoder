use super::*;
use crate::agents::jobs::model::*;
use crate::agents::jobs::store::fingerprint;
use crate::test_support::TestGateway;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;

#[tokio::test]
async fn cluster_reachable_member_expedites_its_pending_delivery() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let gateway = TestGateway::with_native_runtime(directory.path());
    let link = gateway.cluster_link().await?;
    let host = crate::ids::new_session_uuid();
    let membership = crate::ids::new_session_uuid();
    let incarnation = crate::ids::new_session_uuid();
    let credential = link
        .store
        .issue(IssueParams {
            protocol: PROTOCOL,
            r#for: host.clone(),
            name: "receiver".into(),
            membership: membership.clone(),
        })
        .await?;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let identity = crate::http::lan_identity::LanIdentity::load(
        &directory.path().join("tls.der"),
        "127.0.0.1".into(),
    )?;
    let record = link
        .store
        .accept(AcceptParams {
            protocol: PROTOCOL,
            host: host.clone(),
            name: "receiver".into(),
            membership,
            pin: identity.spki_sha256.clone(),
            credential,
            routes: vec![format!("wss://{}/ws", listener.local_addr()?)],
        })
        .await?;
    let refused = tokio::spawn(async move {
        for _ in 0..2 {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream);
        }
        listener
    });
    let store = gateway.jobs.store().await?;
    let mut job = crate::agents::jobs::store_tests::job(87);
    job.recipient = Recipient::Remote {
        host: host.clone(),
        incarnation: incarnation.clone(),
        conversation: ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known {
                path: directory.path().join("codex"),
            },
            thread_id: crate::ids::new_session_uuid(),
        },
    };
    let (job, _) = store.admit(job).await?;
    let at = crate::time::unix_millis() - 60 * 60 * 1000;
    let job = store
        .advance(
            job.job_id.clone(),
            job.revision,
            ExecutionState::Terminal {
                terminal: Terminal {
                    at_ms: Some(at),
                    execution: None,
                    git: GitSnapshot::Unknown {
                        reason: "fixture".into(),
                    },
                    outcome: JobOutcome::Completed,
                    result: ResultEvidence::Unavailable {
                        reason: "fixture".into(),
                    },
                    completion: Completion::Required {
                        payload: CompletionPayload::Prepared {
                            delivery_id: format!("{}:completion", job.job_id.as_str()),
                            fingerprint: fingerprint(b"Child finished."),
                            text: "Child finished.".into(),
                        },
                        delivery: DeliveryState::Pending,
                    },
                    cleanup: CleanupState::Complete,
                },
            },
            at,
        )
        .await?;
    gateway.jobs.deliver_obligations(job.clone()).await?;
    let deadline = gateway
        .jobs
        .next_delivery_due()
        .expect("failed delivery has backoff");
    assert!(deadline > tokio::time::Instant::now() + Duration::from_secs(60));
    let listener = refused.await?;
    let (release, released) = oneshot::channel();
    let hello = HelloReceipt {
        protocol: PROTOCOL,
        version: "fixture".into(),
        host: host.clone(),
        incarnation,
        capabilities: CAPABILITIES
            .iter()
            .map(|capability| (*capability).into())
            .collect(),
        routes: vec![],
        load: HostLoad {
            cpu_percent: None,
            memory_pressure: None,
            active_agents: 0,
        },
    };
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let stream = identity.acceptor.accept(stream).await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        socket
            .send(Message::Text(json!({"method":"daemon/ready"}).to_string()))
            .await
            .unwrap();
        for method in ["cluster/hello", "agent/jobs/deliver"] {
            let request = loop {
                match socket.next().await.unwrap().unwrap() {
                    Message::Text(text) => {
                        break serde_json::from_str::<serde_json::Value>(&text).unwrap();
                    }
                    Message::Ping(value) => socket.send(Message::Pong(value)).await.unwrap(),
                    other => panic!("unexpected peer message: {other:?}"),
                }
            };
            assert_eq!(request["method"], method);
            let result = if method == "cluster/hello" {
                json!(hello)
            } else {
                json!({"deliveryState":DeliveryState::Accepted { receipt: "fixture".into() }})
            };
            socket
                .send(Message::Text(
                    json!({"id":request["id"],"result":result}).to_string(),
                ))
                .await
                .unwrap();
        }
        released.await.unwrap();
    });
    let shutdown = tokio_util::sync::CancellationToken::new();
    let worker = tokio::spawn(member_worker(
        Arc::downgrade(&gateway),
        record,
        Arc::new(tokio::sync::Semaphore::new(1)),
        shutdown.clone(),
    ));
    let mut changes = store.member_changes(host.clone()).await?;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let latest = store.read(job.job_id.clone()).await?;
            if matches!(latest.execution, ExecutionState::Terminal { terminal }
                if matches!(terminal.completion, Completion::Required { delivery: DeliveryState::Accepted { .. }, .. })) {
                break Ok::<_, anyhow::Error>(());
            }
            changes.changed().await?;
        }
    }).await??;
    assert!(tokio::time::Instant::now() < deadline);
    assert_eq!(
        link.members().await?[0].reachability.state,
        crate::cluster::link::ReachabilityState::Reachable
    );
    shutdown.cancel();
    worker.await??;
    release.send(()).unwrap();
    server.await?;
    Ok(())
}
