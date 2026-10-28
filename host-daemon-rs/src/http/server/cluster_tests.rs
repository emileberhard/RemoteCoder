use super::harness::{HOST, LanHarness, OPERATOR};
use crate::agents::jobs::model::*;
use crate::wire::cluster::*;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_rustls::client::TlsStream<tokio::net::TcpStream>>;

async fn connect(host: &LanHarness, token: &str) -> Socket {
    let stream = host.connect(&host.pin).await.unwrap();
    let mut request = format!("wss://{HOST}/ws").into_client_request().unwrap();
    request
        .headers_mut()
        .insert("Authorization", format!("Bearer {token}").parse().unwrap());
    let (mut socket, _) = tokio_tungstenite::client_async(request, stream)
        .await
        .unwrap();
    loop {
        if let Message::Text(text) = socket.next().await.unwrap().unwrap()
            && serde_json::from_str::<Value>(&text).unwrap()["method"] == "daemon/ready"
        {
            break;
        }
    }
    socket
}

async fn request(socket: &mut Socket, method: &str, params: Value) -> Value {
    socket
        .send(Message::Text(
            json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}).to_string(),
        ))
        .await
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            if let Message::Text(text) = socket.next().await.unwrap().unwrap() {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["id"] == 1 {
                    return value;
                }
            }
        }
    })
    .await
    .unwrap()
}

async fn rpc(host: &LanHarness, method: &str, params: Value) -> Value {
    let mut socket = connect(host, OPERATOR).await;
    let response = request(&mut socket, method, params).await;
    socket.close(None).await.unwrap();
    assert!(response.get("error").is_none(), "{}", response["error"]);
    response["result"].clone()
}

async fn pair(
    left: &LanHarness,
    right: &LanHarness,
    left_name: &str,
    right_name: &str,
) -> (String, String) {
    let a = left.gateway.host_identity().await.unwrap();
    let b = right.gateway.host_identity().await.unwrap();
    let membership = crate::ids::new_session_uuid();
    let issued = rpc(
        left,
        "cluster/issue",
        json!({"protocol":PROTOCOL,"for":b.host_id,"name":right_name,"membership":membership}),
    )
    .await;
    let repeated = rpc(
        left,
        "cluster/issue",
        json!({"protocol":PROTOCOL,"for":b.host_id,"name":right_name,"membership":membership}),
    )
    .await;
    assert_eq!(issued["credential"], repeated["credential"]);
    let received = rpc(
        right,
        "cluster/issue",
        json!({"protocol":PROTOCOL,"for":a.host_id,"name":left_name,"membership":membership}),
    )
    .await;
    for (host, receipt, name) in [(left, &received, right_name), (right, &issued, left_name)] {
        rpc(host,"cluster/accept",json!({"protocol":PROTOCOL,"host":receipt["host"],"name":name,"membership":membership,"pin":receipt["pin"],"routes":receipt["routes"],"credential":receipt["credential"]})).await;
    }
    (
        membership,
        received["credential"].as_str().unwrap().to_owned(),
    )
}

fn spec(root: &std::path::Path) -> JobSpec {
    JobSpec {
        prompt: "Read the fixture".into(),
        cwd: root.into(),
        settings: ExecutionSettings::Codex {
            model: "gpt-6.1-sol".into(),
            model_provider: "openai".into(),
            effort: "medium".into(),
            service_tier: None,
            cyber_access_program: None,
        },
        tool_scope: ToolScope::Full,
        title: None,
    }
}

#[tokio::test]
async fn cluster_peer_search_stays_local_without_recursive_coverage() {
    let a = LanHarness::start().await;
    let b = LanHarness::start().await;
    pair(&a, &b, "a", "b").await;
    let identity = b.gateway.host_identity().await.unwrap();
    let result = a
        .gateway
        .cluster_link()
        .await
        .unwrap()
        .call(
            &identity.host_id,
            "sessions/search",
            json!({"query":"fixture","local":false}),
        )
        .await
        .unwrap();
    assert_eq!(result["schemaVersion"], 1);
    assert!(
        result["coverage"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row.get("hostId").is_none())
    );
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn cluster_fault_capacity_refuses_before_provider_custody() {
    let a = LanHarness::start().await;
    let b = LanHarness::start().await;
    pair(&a, &b, "a", "b").await;
    let mut admitted = 0;
    for index in 0..MAX_UNSETTLED_JOBS {
        let result = b
            .gateway
            .jobs
            .start(
                crate::wire::agent_jobs::StartParams {
                    job_id: JobId::for_mutation(Provider::Codex, &format!("fill-{index}")).unwrap(),
                    spec: spec(b.directory.path()),
                    caller: crate::wire::agent_jobs::Caller::Operator,
                },
                Origin::TopLevel,
            )
            .await;
        match result {
            Ok(_) => admitted += 1,
            Err(error) => {
                assert!(error.to_string().contains("cap"));
                break;
            }
        }
    }
    assert!(admitted > 0);
    let mut operator = connect(&a, OPERATOR).await;
    let response=request(&mut operator,"agent/cluster/dispatch",json!({"host":"b","method":"agent/jobs/start","request":{"jobId":JobId::for_mutation(Provider::Codex,"over-capacity").unwrap(),"spec":spec(b.directory.path()),"caller":{"kind":"operator"}},"caller":{"kind":"operator"}})).await;
    assert_eq!(response["error"]["data"]["class"], "refused");
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("cap")
    );
    assert_eq!(
        b.gateway
            .jobs
            .store()
            .await
            .unwrap()
            .agent_rows()
            .await
            .unwrap()
            .len(),
        admitted
    );
    assert_eq!(
        a.gateway
            .jobs
            .store()
            .await
            .unwrap()
            .intents()
            .await
            .unwrap()[0]
            .state,
        IntentState::Abandoned
    );
    operator.close(None).await.unwrap();
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn cluster_fault_admission_replay_fences_and_incarnation() {
    let a = LanHarness::start().await;
    let b = LanHarness::start().await;
    let (membership, _) = pair(&a, &b, "a", "b").await;
    let identity = b.gateway.host_identity().await.unwrap();
    let link = a.gateway.cluster_link().await.unwrap();
    let id = JobId::for_mutation(Provider::Codex, "cluster-lost-admit-reply").unwrap();
    let start = json!({"jobId":id,"spec":spec(b.directory.path()),"caller":{"kind":"operator"}});
    let first=rpc(&a,"agent/cluster/dispatch",json!({"host":"b","method":"agent/jobs/start","request":start,"caller":{"kind":"operator"}})).await;
    assert_eq!(first["ownerHostId"], identity.host_id);
    assert!(first["address"].is_null());
    let intent = a
        .gateway
        .jobs
        .store()
        .await
        .unwrap()
        .intents()
        .await
        .unwrap()
        .pop()
        .unwrap();
    a.gateway
        .jobs
        .store()
        .await
        .unwrap()
        .intent_state(id.clone(), IntentState::Pending)
        .await
        .unwrap();
    let replay = link
        .call(&identity.host_id, "agent/jobs/admit", json!(intent.request))
        .await
        .unwrap();
    assert_eq!(replay["duplicate"], true);
    assert_eq!(replay["jobId"], id.as_str());
    assert_eq!(
        b.gateway
            .jobs
            .store()
            .await
            .unwrap()
            .agent_rows()
            .await
            .unwrap()
            .len(),
        1
    );
    let mut changed = intent.request.clone();
    let AdmissionOperation::Start(spec) = &mut changed.operation else {
        unreachable!()
    };
    spec.prompt = "Changed inputs".into();
    let conflict = link
        .call(&identity.host_id, "agent/jobs/admit", json!(changed))
        .await
        .unwrap_err();
    assert_eq!(conflict.class, ErrorClass::Refused);
    let steer = link.call(&identity.host_id,"agent/jobs/message",json!(ForwardParams {
        protocol:PROTOCOL,incarnation:identity.incarnation.clone(),
        caller_authority:CallerAuthority::Agent {conversation:ConversationIdentity {provider:Provider::Codex,provider_home:ProviderHome::Known {path:a.directory.path().into()},thread_id:"restricted-parent".into()},scope:ToolScope::ReadOnly {root:a.directory.path().into()}},
        request:json!({"target":{"kind":"job","jobId":id},"caller":{"kind":"operator"},"deliveryId":"restricted-steer","text":"must not steer full-access work"}),
    })).await.unwrap_err();
    assert_eq!(steer.class, ErrorClass::Refused);
    let mut changed = intent.request.clone();
    changed.operation = AdmissionOperation::Continue(crate::wire::agent_jobs::ContinueParams {
        job_id: id.clone(),
        agent_id: id.as_str().into(),
        prompt: "Different operation".into(),
        settings: None,
        expected_previous_job_id: None,
        intent: Default::default(),
        recipient: crate::wire::agent_jobs::ContinueRecipient::Current,
        caller: crate::wire::agent_jobs::Caller::Operator,
    });
    changed.fingerprint = crate::agents::jobs::store::fingerprint(
        &serde_json::to_vec(&(
            changed.protocol,
            &changed.job_id,
            &changed.incarnation,
            &changed.origin,
            &changed.recipient,
            &changed.operation,
            &changed.caller_authority,
        ))
        .unwrap(),
    );
    assert_eq!(
        link.call(&identity.host_id, "agent/jobs/admit", json!(changed))
            .await
            .unwrap_err()
            .class,
        ErrorClass::Conflict
    );
    let cancelled = JobId::for_mutation(Provider::Codex, "cluster-stop-before-admit").unwrap();
    link.call(
        &identity.host_id,
        "agent/jobs/stop",
        json!({"protocol":PROTOCOL,"jobId":cancelled}),
    )
    .await
    .unwrap();
    let admitted=rpc(&a,"agent/cluster/dispatch",json!({"host":"b","method":"agent/jobs/start","request":{"jobId":cancelled,"spec":spec(b.directory.path()),"caller":{"kind":"operator"}},"caller":{"kind":"operator"}})).await;
    assert_eq!(admitted["state"], "interrupted");
    let job = b
        .gateway
        .jobs
        .store()
        .await
        .unwrap()
        .read(cancelled)
        .await
        .unwrap();
    assert!(matches!(job.stop, StopState::Requested { .. }));
    assert!(job.execution.conversation().is_none());
    assert_eq!(
        job.admitted_membership.as_deref(),
        Some(membership.as_str())
    );
    let stale=link.call(&identity.host_id,"agent/jobs/deliver",json!({"protocol":PROTOCOL,"conversation":{"provider":"codex","providerHome":{"kind":"known","path":b.directory.path()},"threadId":"never-start"},"incarnation":crate::ids::new_session_uuid(),"deliveryId":"stale","text":"must not enter native custody"})).await.unwrap_err();
    assert_eq!(stale.class, ErrorClass::Uncertain);
    let mut forged = intent.request;
    forged.job_id = JobId::for_mutation(Provider::Codex, "forged-origin").unwrap();
    forged.origin = Origin::RemoteParent {
        host: crate::ids::new_session_uuid(),
        conversation: ConversationIdentity {
            provider: Provider::Codex,
            provider_home: ProviderHome::Known {
                path: "/tmp".into(),
            },
            thread_id: "forged".into(),
        },
    };
    assert_eq!(
        link.call(&identity.host_id, "agent/jobs/admit", json!(forged))
            .await
            .unwrap_err()
            .class,
        ErrorClass::Refused
    );
    let store = a.gateway.jobs.store().await.unwrap();
    store
        .intent_state(id.clone(), IntentState::StopRequested)
        .await
        .unwrap();
    assert!(
        !a.gateway
            .reconcile_cluster_member(&identity.host_id)
            .await
            .unwrap()
    );
    let stopped = b
        .gateway
        .jobs
        .store()
        .await
        .unwrap()
        .read(id.clone())
        .await
        .unwrap();
    assert!(matches!(stopped.stop, StopState::Requested { .. }));
    assert!(
        store
            .intents()
            .await
            .unwrap()
            .iter()
            .find(|intent| intent.request.job_id == id)
            .unwrap()
            .stop_confirmed
    );
    let changed = crate::ids::new_session_uuid();
    let a_identity = a.gateway.host_identity().await.unwrap();
    b.gateway
        .cluster_link()
        .await
        .unwrap()
        .call(
            &a_identity.host_id,
            "cluster/hello",
            json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":changed}),
        )
        .await
        .unwrap();
    assert_eq!(
        store
            .intents()
            .await
            .unwrap()
            .iter()
            .find(|intent| intent.request.job_id == id)
            .unwrap()
            .state,
        IntentState::Unknown
    );
    assert!(
        !a.gateway
            .reconcile_cluster_member(&identity.host_id)
            .await
            .unwrap()
    );
    assert_eq!(
        b.gateway
            .jobs
            .store()
            .await
            .unwrap()
            .agent_rows()
            .await
            .unwrap()
            .len(),
        2
    );
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn cluster_fault_remove_revokes_open_sockets_and_tombstones_delayed_join() {
    let a = LanHarness::start().await;
    let b = LanHarness::start().await;
    let (membership, credential) = pair(&a, &b, "a", "b").await;
    let a_id = a.gateway.host_identity().await.unwrap();
    let b_id = b.gateway.host_identity().await.unwrap();
    let mut peer = connect(&b, &credential).await;
    let work = JobId::for_mutation(Provider::Codex, "removed-mid-job").unwrap();
    rpc(&a,"agent/cluster/dispatch",json!({"host":"b","method":"agent/jobs/start","request":{"jobId":work,"spec":spec(b.directory.path()),"caller":{"kind":"operator"}},"caller":{"kind":"operator"}})).await;
    let forbidden=request(&mut peer,"cluster/issue",json!({"protocol":PROTOCOL,"for":crate::ids::new_session_uuid(),"name":"forged","membership":crate::ids::new_session_uuid()})).await;
    assert_eq!(forbidden["error"]["data"]["class"], "refused");
    let removed = rpc(
        &a,
        "cluster/remove",
        json!({"protocol":PROTOCOL,"host":b_id.host_id,"membership":membership}),
    )
    .await;
    assert_eq!(removed["pending"], false);
    assert!(matches!(
        b.gateway
            .jobs
            .store()
            .await
            .unwrap()
            .read(work.clone())
            .await
            .unwrap()
            .stop,
        StopState::Requested { .. }
    ));
    assert_eq!(
        a.gateway
            .jobs
            .store()
            .await
            .unwrap()
            .intents()
            .await
            .unwrap()[0]
            .state,
        IntentState::Removed
    );
    let denied = request(&mut peer, "cluster/list", json!({})).await;
    assert_eq!(denied["error"]["data"]["class"], "refused");
    peer.close(None).await.unwrap();
    let mut operator = connect(&b, OPERATOR).await;
    let delayed = request(
        &mut operator,
        "cluster/issue",
        json!({"protocol":PROTOCOL,"for":a_id.host_id,"name":"a","membership":membership}),
    )
    .await;
    assert_eq!(delayed["error"]["data"]["class"], "refused");
    operator.close(None).await.unwrap();
    assert!(
        rpc(&a, "cluster/list", json!({})).await["members"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    pair(&a, &b, "a", "b").await;
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn cluster_three_member_pinned_links_report_typed_load() {
    let a = LanHarness::start().await;
    let b = LanHarness::start().await;
    let c = LanHarness::start().await;
    pair(&a, &b, "a", "b").await;
    pair(&a, &c, "a", "c").await;
    pair(&b, &c, "b", "c").await;
    for host in [&a, &b, &c] {
        let identity = host.gateway.host_identity().await.unwrap();
        let link = host.gateway.cluster_link().await.unwrap();
        let peers = link.members().await.unwrap();
        assert_eq!(peers.len(), 2);
        for peer in peers {
            let hello=link.call(&peer.host,"cluster/hello",json!({"protocol":PROTOCOL,"host":identity.host_id,"incarnation":identity.incarnation})).await.unwrap();
            assert_eq!(hello["host"], peer.host);
            assert!(hello["load"]["activeAgents"].is_u64());
            assert!(
                hello["load"]["memoryPressure"].is_null()
                    || ["normal", "warn", "critical"]
                        .contains(&hello["load"]["memoryPressure"].as_str().unwrap())
            );
        }
        assert!(
            rpc(host, "cluster/list", json!({})).await["members"]
                .as_array()
                .unwrap()
                .iter()
                .all(|member| member["reachability"]["state"] == "reachable")
        );
    }
    a.stop().await;
    b.stop().await;
    c.stop().await;
}
