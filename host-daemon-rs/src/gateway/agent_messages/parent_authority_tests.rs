use super::*;
use crate::agents::jobs::model::*;
use crate::test_support::TestGateway;
use crate::wire::cluster::{AgentAddress, CallerAuthority};

fn message(sender: ConversationIdentity) -> MessageRecord {
    MessageRecord {
        delivery_id: "parent-progress".into(),
        request_fingerprint: "fixture-request".into(),
        payload_fingerprint: "fixture-payload".into(),
        sender: Origin::Parent {
            conversation: sender,
        },
        requested_target: MessageTarget::Parent,
        text: Some("Progress update".into()),
        resolved: None,
        delivery_state: DeliveryState::Pending,
        created_at_ms: 1,
        updated_at_ms: 1,
    }
}

fn caller(sender: ConversationIdentity) -> Caller {
    Caller::Forwarded {
        admission_fingerprint: None,
        host: "00000000-0000-4000-8000-000000000041".into(),
        membership: "00000000-0000-4000-8000-000000000042".into(),
        incarnation: "00000000-0000-4000-8000-000000000043".into(),
        authority: CallerAuthority::Agent {
            conversation: sender,
            scope: ToolScope::ReadOnly {
                root: "/tmp".into(),
            },
        },
    }
}

async fn register(
    gateway: &Gateway,
    id: &str,
    conversation: ConversationIdentity,
    origin: Origin,
    parent: Option<AgentAddress>,
    recipient: Recipient,
    scope: ToolScope,
) {
    gateway
        .jobs
        .store()
        .await
        .unwrap()
        .adopt_conversation(AgentRecord {
            agent_id: id.into(),
            parent,
            parent_revision: 0,
            parent_recipient: Some(recipient),
            conversation: ConversationBinding::Known { conversation },
            origin,
            tool_scope: Some(scope),
            origin_job_id: None,
            latest_job_id: None,
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn read_only_parent_messages_use_immutable_native_ancestry_without_authorizing_arbitrary_steering()
 {
    let gateway = TestGateway::new();
    let host = gateway.host_identity().await.unwrap().host_id;
    let sender = gateway
        .agent_conversation("00000000-0000-4000-8000-000000000051")
        .unwrap();
    let parent = gateway
        .agent_conversation("00000000-0000-4000-8000-000000000052")
        .unwrap();
    let unrelated = gateway
        .agent_conversation("00000000-0000-4000-8000-000000000053")
        .unwrap();
    for (id, conversation) in [
        ("full-parent", parent.clone()),
        ("unrelated-full-target", unrelated.clone()),
    ] {
        register(
            &gateway,
            id,
            conversation,
            Origin::TopLevel,
            None,
            Recipient::None,
            ToolScope::Full,
        )
        .await;
    }
    register(
        &gateway,
        "readonly-child",
        sender.clone(),
        Origin::Parent {
            conversation: parent.clone(),
        },
        Some(AgentAddress {
            host_id: host.clone(),
            thread_id: parent.thread_id.clone(),
        }),
        Recipient::Conversation {
            conversation: parent.clone(),
        },
        ToolScope::ReadOnly {
            root: "/tmp".into(),
        },
    )
    .await;
    let caller = caller(sender.clone());
    let mut record = message(sender);
    let original = gateway.resolve_message_target(&record).await.unwrap();
    assert_eq!(original.conversation, parent);
    gateway
        .authorize_message_target(&caller, &record, &original)
        .await
        .unwrap();
    record.requested_target = MessageTarget::Conversation {
        conversation: parent.clone(),
    };
    assert!(
        gateway
            .authorize_message_target(&caller, &record, &original)
            .await
            .is_err()
    );
    record.requested_target = MessageTarget::Parent;
    gateway
        .jobs
        .store()
        .await
        .unwrap()
        .set_parent_for_test(
            "readonly-child".into(),
            Some(AgentAddress {
                host_id: host,
                thread_id: unrelated.thread_id.clone(),
            }),
            Recipient::Conversation {
                conversation: unrelated.clone(),
            },
        )
        .await
        .unwrap();
    let moved = gateway.resolve_message_target(&record).await.unwrap();
    assert_eq!(moved.conversation, unrelated);
    assert!(
        gateway
            .authorize_message_target(&caller, &record, &moved)
            .await
            .is_err()
    );
    gateway
        .authorize_message_target(&caller, &record, &original)
        .await
        .unwrap();
}

#[tokio::test]
async fn read_only_remote_parent_messages_require_the_exact_immutable_host_and_conversation() {
    let gateway = TestGateway::new();
    let sender = gateway
        .agent_conversation("00000000-0000-4000-8000-000000000061")
        .unwrap();
    let parent = ConversationIdentity {
        provider: Provider::Codex,
        provider_home: ProviderHome::Known {
            path: "/remote/.codex".into(),
        },
        thread_id: "00000000-0000-4000-8000-000000000062".into(),
    };
    let host = "00000000-0000-4000-8000-000000000063";
    let recipient = Recipient::Remote {
        host: host.into(),
        incarnation: "00000000-0000-4000-8000-000000000064".into(),
        conversation: parent.clone(),
    };
    register(
        &gateway,
        "remote-readonly-child",
        sender.clone(),
        Origin::RemoteParent {
            host: host.into(),
            conversation: parent.clone(),
        },
        Some(AgentAddress {
            host_id: host.into(),
            thread_id: parent.thread_id.clone(),
        }),
        recipient,
        ToolScope::ReadOnly {
            root: "/tmp".into(),
        },
    )
    .await;
    let caller = caller(sender.clone());
    let record = message(sender);
    let mut resolved = gateway.resolve_message_target(&record).await.unwrap();
    gateway
        .authorize_message_target(&caller, &record, &resolved)
        .await
        .unwrap();
    let Some(Recipient::Remote { host, .. }) = &mut resolved.remote_recipient else {
        panic!("missing remote parent");
    };
    *host = "00000000-0000-4000-8000-000000000065".into();
    assert!(
        gateway
            .authorize_message_target(&caller, &record, &resolved)
            .await
            .is_err()
    );
    let mut resolved = gateway.resolve_message_target(&record).await.unwrap();
    resolved.conversation.thread_id = "00000000-0000-4000-8000-000000000066".into();
    assert!(
        gateway
            .authorize_message_target(&caller, &record, &resolved)
            .await
            .is_err()
    );
}
