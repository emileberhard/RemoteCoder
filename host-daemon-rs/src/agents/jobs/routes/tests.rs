use super::*;
use crate::agents::jobs::model::{ConversationIdentity, JobId, Provider, ProviderHome};
use crate::platform::process::{ProcessInstance, identify};
use crate::providers::claude::native_parent::{NativeParentForwarder, NativeSessionOwner};
use crate::wire::agent_jobs::ScopedRequest;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

fn owner() -> ProcessInstance {
    let pid = std::process::id() as i32;
    ProcessInstance {
        pid,
        started_micros: identify(pid).unwrap().unwrap().started_micros,
    }
}

fn conversation() -> ConversationIdentity {
    ConversationIdentity {
        provider: Provider::Claude,
        provider_home: ProviderHome::Known {
            path: "/isolated/claude".into(),
        },
        thread_id: "claude_11111111-2222-4333-8444-555555555555".into(),
    }
}

fn recorded_owner(
    directory: &std::path::Path,
    path: &std::path::Path,
) -> (ConversationIdentity, NativeSessionOwner) {
    let process = owner();
    let mut conversation = conversation();
    conversation.provider_home = ProviderHome::Known {
        path: directory.into(),
    };
    let native = NativeSessionOwner {
        pid: process.pid,
        started_micros: process.started_micros,
        session_uuid: "11111111-2222-4333-8444-555555555555".into(),
        cwd: directory.into(),
        socket_path: path.into(),
    };
    let format = time::format_description::parse_owned::<3>("[weekday repr:short] [month repr:short] [day padding:space] [hour]:[minute]:[second] [year]").unwrap();
    let started =
        time::OffsetDateTime::from_unix_timestamp((process.started_micros / 1_000_000) as i64)
            .unwrap()
            .format(&format)
            .unwrap();
    std::fs::create_dir_all(directory.join("sessions")).unwrap();
    std::fs::write(directory.join("sessions").join(format!("{}.json", process.pid)), serde_json::to_vec(&json!({
        "pid":process.pid,"sessionId":native.session_uuid,"cwd":directory,"messagingSocketPath":path,"pidDomain":"darwin","procStart":started
    })).unwrap()).unwrap();
    (conversation, native)
}

#[tokio::test]
async fn lost_holder_receipt_is_uncertain_and_an_old_lease_cannot_remove_a_replacement() {
    let routes = NativeRoutes::default();
    let conversation = conversation();
    let (old, receiver) = routes.register(conversation.clone(), owner()).unwrap();
    drop(receiver);
    let (lease, mut receiver) = routes.register(conversation.clone(), owner()).unwrap();
    drop(old);
    let receive = tokio::spawn(async move {
        let request = receiver.recv().await.unwrap();
        drop(request.reply);
    });
    let message = NativeMessage::new(
        conversation.clone(),
        "completion-1".into(),
        "finished work".into(),
    )
    .unwrap();
    assert!(matches!(
        routes.deliver(&conversation, message).await,
        NativeDeliveryState::Uncertain { .. }
    ));
    receive.await.unwrap();
    drop(lease);
    let message = NativeMessage::new(
        conversation.clone(),
        "completion-1".into(),
        "finished work".into(),
    )
    .unwrap();
    assert!(matches!(
        routes.deliver(&conversation, message).await,
        NativeDeliveryState::Unreachable { .. }
    ));
}

#[test]
fn native_wire_cannot_change_input_identity_or_smuggle_an_execution_frame() {
    let message = NativeMessage::new(
        conversation(),
        "completion-1".into(),
        "finished work".into(),
    )
    .unwrap();
    let mut value = serde_json::to_value(message).unwrap();
    value["inputId"] = json!("other");
    assert!(serde_json::from_value::<NativeMessage>(value.clone()).is_err());
    value["type"] = json!("control_request");
    assert!(serde_json::from_value::<NativeMessage>(value).is_err());
}

#[tokio::test]
async fn native_forwarder_writes_only_auth_and_exact_user_input_without_claiming_acceptance() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let path = directory.path().join("native");
    let listener = UnixListener::bind(&path).unwrap();
    let (conversation, native) = recorded_owner(directory.path(), &path);
    let message = NativeMessage::new(
        conversation.clone(),
        "completion-1".into(),
        "finished work".into(),
    )
    .unwrap();
    let expected_input = message.input_id().to_owned();
    let forwarder =
        NativeParentForwarder::new(conversation, native, "isolated-process-token".into()).unwrap();
    let receiver = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut lines = BufReader::new(stream).lines();
        let auth: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        let user: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(
            auth,
            json!({"type":"auth","token":"isolated-process-token"})
        );
        assert_eq!(
            user,
            json!({"type":"user","uuid":expected_input,"message":{"role":"user","content":"finished work"}})
        );
        assert!(lines.next_line().await.unwrap().is_none());
    });
    assert_eq!(
        forwarder.forward(&message).await,
        NativeDeliveryState::Submitted
    );
    receiver.await.unwrap();
}

#[tokio::test]
async fn native_forwarder_does_not_disclose_token_to_a_changed_process_identity() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let path = directory.path().join("native");
    let listener = UnixListener::bind(&path).unwrap();
    let (conversation, mut native) = recorded_owner(directory.path(), &path);
    native.started_micros += 1;
    let message = NativeMessage::new(
        conversation.clone(),
        "completion-1".into(),
        "finished work".into(),
    )
    .unwrap();
    let forwarder =
        NativeParentForwarder::new(conversation, native, "isolated-process-token".into()).unwrap();
    assert!(matches!(
        forwarder.forward(&message).await,
        NativeDeliveryState::Unreachable { .. }
    ));
    assert!(
        tokio::time::timeout(Duration::from_millis(30), listener.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn scoped_endpoint_supplies_kernel_peer_identity_and_closes_its_readers() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let path = directory.path().join("scoped");
    let job_id = JobId::try_from("agent-claude-2026102720000000000-abcdef12".to_owned()).unwrap();
    let expected_job = job_id.clone();
    let expected_peer = owner();
    let handler: ScopedHandler = Arc::new(move |job, peer, request| {
        assert_eq!(job, expected_job);
        assert_eq!(peer, expected_peer);
        assert!(matches!(request, ScopedRequest::ReadSelf {}));
        Box::pin(async { Ok(json!({"verified":true})) })
    });
    let lease = ScopedEndpoints::default()
        .bind(&path, job_id, handler)
        .unwrap();
    let mut stream = UnixStream::connect(&path).await.unwrap();
    stream
        .write_all(b"{\"method\":\"readSelf\",\"params\":{}}\n")
        .await
        .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).await.unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap(),
        json!({"result":{"verified":true}})
    );
    let mut unfinished = UnixStream::connect(&path).await.unwrap();
    unfinished.write_all(b"{").await.unwrap();
    lease.close().await;
    assert!(!path.exists());
    let mut response = Vec::new();
    let closed = tokio::time::timeout(
        Duration::from_secs(1),
        unfinished.read_to_end(&mut response),
    )
    .await;
    assert!(closed.is_ok());
}
