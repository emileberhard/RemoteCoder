use super::super::LauncherPurpose;
use super::AgentService;
use crate::agents::launcher;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio::time::Instant;

const ENTRY_LIMIT: usize = 4_096;
const BYTE_LIMIT: usize = 4 * 1_024 * 1_024;
const UNKNOWN_RETRY: Duration = Duration::from_secs(30);
const IN_FLIGHT_LIMIT: usize = 1_024;
const WAITER_LIMIT: usize = 256;

type Subject = (PathBuf, String);
type Results = HashMap<Subject, Ancestry>;
type Pending = Arc<watch::Sender<Option<Ancestry>>>;

#[derive(Clone)]
enum Ancestry {
    Root,
    Child(Value),
    Unknown(Vec<&'static str>),
}

struct Entry {
    ancestry: Ancestry,
    at: Instant,
    access: u64,
    bytes: usize,
}

#[derive(Default)]
struct Cache {
    entries: HashMap<Subject, Entry>,
    access: u64,
    bytes: usize,
}

#[derive(Default)]
struct ClassificationState {
    cache: Cache,
    pending: HashMap<Subject, Pending>,
}

#[derive(Default)]
pub(in crate::gateway::agent_gateway) struct Classifications {
    state: Mutex<ClassificationState>,
}

struct Claimed<'a> {
    results: Results,
    owned: InFlight<'a>,
    waiting: Vec<(Subject, watch::Receiver<Option<Ancestry>>)>,
}

struct InFlight<'a> {
    owner: &'a Classifications,
    subjects: Vec<(Subject, Pending)>,
}

impl Classifications {
    pub(in crate::gateway::agent_gateway) async fn classify(
        &self,
        service: &AgentService<'_>,
        ids: Vec<String>,
    ) -> Result<Value> {
        let mut subjects = Vec::new();
        for id in ids {
            crate::questions::validate_id(&id)?;
            let home = service.gateway.agent_home_for_thread(&id)?;
            if !subjects.contains(&(home.clone(), id.clone())) {
                subjects.push((home, id));
            }
        }
        let Claimed {
            mut results,
            mut owned,
            waiting,
        } = self.claim(&subjects)?;
        if !owned.subjects.is_empty() {
            let missing: Vec<_> = owned
                .subjects
                .iter()
                .map(|(subject, _)| subject.clone())
                .collect();
            let resolved = Self::resolve(service, &missing).await?;
            owned.complete(&resolved)?;
            results.extend(resolved);
        }
        for (subject, mut pending) in waiting {
            loop {
                let value = pending.borrow().clone();
                if let Some(value) = value {
                    results.insert(subject, value);
                    break;
                }
                pending
                    .changed()
                    .await
                    .context("Agent classification ended without a result")?;
            }
        }
        let mut relations = serde_json::Map::new();
        let mut roots = Vec::new();
        let mut warnings = Vec::new();
        for key in subjects {
            match results
                .remove(&key)
                .context("Classification result is missing")?
            {
                Ancestry::Root => roots.push(key.1),
                Ancestry::Child(relation) => {
                    relations.insert(key.1, relation);
                }
                Ancestry::Unknown(reasons) => warnings.extend(reasons),
            }
        }
        warnings.sort();
        warnings.dedup();
        Ok(json!({"relations":relations,"knownRoots":roots,"warnings":warnings}))
    }

    fn claim<'a>(&'a self, subjects: &[Subject]) -> Result<Claimed<'a>> {
        let mut state = self.state.lock().expect("Classification state poisoned");
        let (results, missing) = state.cache.lookup(subjects);
        let new = missing
            .iter()
            .filter(|subject| !state.pending.contains_key(*subject))
            .count();
        ensure!(
            state.pending.len() + new <= IN_FLIGHT_LIMIT,
            "Agent classification is busy; retry shortly"
        );
        ensure!(
            missing.iter().all(|subject| state
                .pending
                .get(subject)
                .is_none_or(|pending| pending.receiver_count() < WAITER_LIMIT)),
            "Too many readers waiting for agent classification; retry shortly"
        );
        let mut owned = Vec::new();
        let mut waiting = Vec::new();
        for subject in missing {
            if let Some(pending) = state.pending.get(&subject) {
                waiting.push((subject, pending.subscribe()));
            } else {
                let (sender, _) = watch::channel(None);
                let pending = Arc::new(sender);
                state.pending.insert(subject.clone(), pending.clone());
                owned.push((subject, pending));
            }
        }
        Ok(Claimed {
            results,
            owned: InFlight {
                owner: self,
                subjects: owned,
            },
            waiting,
        })
    }

    async fn resolve(service: &AgentService<'_>, missing: &[Subject]) -> Result<Results> {
        let mut results = HashMap::new();
        let homes = service.gateway.agent_homes()?;
        let response = service
            .gateway
            .call_agent_launcher(
                LauncherPurpose::Inventory,
                json!({"schemaVersion":2,"operation":"classify",
                "homes":homes,"threadIds":missing.iter().map(|(_, id)| id).collect::<Vec<_>>()}),
            )
            .await;
        let mut classified = Vec::new();
        for (home, id) in missing {
            let result = response
                .as_ref()
                .map_err(|_| launcher::unavailable("launcherUnavailable"))
                .and_then(|response| projection(response, home, id, service));
            match result {
                Ok(Some(ancestry)) => classified.push(((home.clone(), id.clone()), ancestry)),
                Ok(None) => classified.push((
                    (home.clone(), id.clone()),
                    Ancestry::Unknown(vec!["parentHomeUnavailable"]),
                )),
                Err(error) => classified.push((
                    (home.clone(), id.clone()),
                    Ancestry::Unknown(super::super::coverage_failure_codes(&error)),
                )),
            }
        }
        results.extend(classified);
        Ok(results)
    }
}

impl InFlight<'_> {
    fn complete(&mut self, results: &Results) -> Result<()> {
        let mut delivered = Vec::new();
        let mut state = self
            .owner
            .state
            .lock()
            .expect("Classification state poisoned");
        for (subject, pending) in &self.subjects {
            let ancestry = results
                .get(subject)
                .context("Owned classification result is missing")?;
            state.cache.insert(subject.clone(), ancestry.clone())?;
            if state
                .pending
                .get(subject)
                .is_some_and(|current| Arc::ptr_eq(current, pending))
            {
                state.pending.remove(subject);
            }
            delivered.push((pending.clone(), ancestry.clone()));
        }
        self.subjects.clear();
        drop(state);
        for (pending, ancestry) in delivered {
            pending.send_replace(Some(ancestry));
        }
        Ok(())
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        if self.subjects.is_empty() {
            return;
        }
        let mut state = self
            .owner
            .state
            .lock()
            .expect("Classification state poisoned");
        for (subject, pending) in &self.subjects {
            if state
                .pending
                .get(subject)
                .is_some_and(|current| Arc::ptr_eq(current, pending))
            {
                state.pending.remove(subject);
            }
        }
        drop(state);
        for (_, pending) in &self.subjects {
            pending.send_replace(Some(Ancestry::Unknown(vec!["classificationCancelled"])));
        }
    }
}

impl Cache {
    fn lookup(&mut self, subjects: &[Subject]) -> (Results, Vec<Subject>) {
        let mut results = HashMap::new();
        let mut missing = Vec::new();
        for key in subjects {
            self.access = self.access.wrapping_add(1);
            match self.entries.get_mut(key) {
                Some(entry)
                    if !matches!(entry.ancestry, Ancestry::Unknown(_))
                        || entry.at.elapsed() < UNKNOWN_RETRY =>
                {
                    entry.access = self.access;
                    results.insert(key.clone(), entry.ancestry.clone());
                }
                _ => missing.push(key.clone()),
            }
        }
        (results, missing)
    }

    fn insert(&mut self, key: Subject, ancestry: Ancestry) -> Result<()> {
        let bytes = key.0.as_os_str().len()
            + key.1.len()
            + match &ancestry {
                Ancestry::Root => 0,
                Ancestry::Child(relation) => serde_json::to_vec(relation)?.len(),
                Ancestry::Unknown(reasons) => reasons.iter().map(|reason| reason.len()).sum(),
            };
        self.access = self.access.wrapping_add(1);
        if let Some(previous) = self.entries.insert(
            key,
            Entry {
                ancestry,
                at: Instant::now(),
                access: self.access,
                bytes,
            },
        ) {
            self.bytes -= previous.bytes;
        }
        self.bytes += bytes;
        while self.entries.len() > ENTRY_LIMIT || self.bytes > BYTE_LIMIT {
            let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.access)
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            if let Some(entry) = self.entries.remove(&oldest) {
                self.bytes -= entry.bytes;
            }
        }
        Ok(())
    }
}

fn subject<'a>(response: &'a Value, home: &std::path::Path, id: &str) -> Option<&'a Value> {
    response["coverage"]["subjects"]
        .as_array()?
        .iter()
        .find(|subject| {
            subject["providerHome"].as_str() == home.to_str()
                && subject["threadId"].as_str() == Some(id)
        })
}

fn projection(
    response: &Value,
    home: &std::path::Path,
    id: &str,
    service: &AgentService<'_>,
) -> Result<Option<Ancestry>> {
    if !launcher::subject_relation(response, home, id)? {
        return Ok(Some(Ancestry::Root));
    }
    let relation =
        &subject(response, home, id).context("Missing verified ancestry subject")?["relation"];
    let parent = relation["parentThreadId"]
        .as_str()
        .context("Missing parent identity")?;
    crate::questions::validate_id(parent)?;
    let parent_home = PathBuf::from(
        relation["parentHome"]
            .as_str()
            .context("Missing parent home")?,
    );
    ensure!(parent_home.is_absolute(), "Parent home must be absolute");
    let run = relation["sourceRunId"]
        .as_str()
        .context("Missing source run identity")?;
    crate::questions::validate_id(run)?;
    if !service
        .gateway
        .agent_home_for_thread(parent)
        .is_ok_and(|home| home == parent_home)
    {
        return Ok(None);
    }
    Ok(Some(Ancestry::Child(json!({"parentThreadId":parent,
        "parentAccountId":null,"agentId":format!("launcher:{run}")}))))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        directory: tempfile::TempDir,
        gateway: crate::test_support::TestGateway,
    }

    impl Fixture {
        fn new() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let gateway = crate::test_support::TestGateway::new();
            let program = directory.path().join("agent-work");
            std::fs::write(&program, r#"#!/usr/bin/python3
import json,pathlib,sys,time
root=pathlib.Path(__file__).parent
request=json.load(sys.stdin)
with (root/'requests').open('a') as log: log.write(json.dumps(request)+'\n')
state=json.loads((root/'state').read_text())
if set(request.get('threadIds',[])).intersection(state.get('hold',[])):
    for thread in request['threadIds']: (root/('started-'+thread)).touch()
    while not (root/'release').exists(): time.sleep(0.01)
if state.get('fail',False): sys.exit(1)
if request.get('schemaVersion')==2:
    subjects=[]
    for thread in request['threadIds']:
        relation=state.get('children',{}).get(thread,{'kind':'root'})
        pending=thread in state.get('unknown',[])
        subjects.append({'providerHome':state['home'],'threadId':thread,
            'status':'incomplete' if pending else 'complete','reasonCodes':['identityPending'] if pending else [],
            'relation':{'kind':'unknown'} if pending else relation})
    response={'schemaVersion':2,'coverage':{'subjects':subjects},'data':[],'nextCursor':None,'warnings':[]}
else:
    response={'schemaVersion':1,'data':state.get('runs',[]),'nextCursor':None,'warnings':[]}
print(json.dumps(response))
"#).unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
            gateway.use_agent_launcher(program);
            let fixture = Self { directory, gateway };
            fixture.state(json!({}));
            fixture
        }

        fn state(&self, mut state: Value) {
            state["home"] = json!(self.gateway.agent_home_for_thread("root").unwrap());
            std::fs::write(self.directory.path().join("state"), state.to_string()).unwrap();
        }

        fn requests(&self) -> Vec<Value> {
            std::fs::read_to_string(self.directory.path().join("requests"))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }

        async fn classify(&self, ids: &[String]) -> Value {
            self.gateway
                .agent_service()
                .agents_rpc("conversation/agents/classify", json!({"threadIds":ids}))
                .await
                .unwrap()
        }

        async fn started(&self, id: &str) {
            let marker = self.directory.path().join(format!("started-{id}"));
            crate::test_support::wait_until("classification launcher to start", move || {
                marker.exists()
            })
            .await;
        }

        fn release(&self) {
            std::fs::write(self.directory.path().join("release"), "").unwrap();
        }
    }

    #[tokio::test]
    async fn classification_batches_only_misses_and_reuses_definitive_ancestry() {
        let fixture = Fixture::new();
        let home = fixture.gateway.agent_home_for_thread("child").unwrap();
        fixture.state(json!({"children":{"child":{"kind":"child","parentHome":home,"parentThreadId":"parent","sourceRunId":"child-run"}}}));
        let first = fixture.classify(&["root".into(), "child".into()]).await;
        assert_eq!(first["knownRoots"], json!(["root"]));
        assert_eq!(first["relations"]["child"]["parentThreadId"], "parent");
        assert!(first["relations"]["child"]["parentAccountId"].is_null());
        fixture
            .classify(&["child".into(), "new-root".into(), "root".into()])
            .await;
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(1_800)).await;
        tokio::time::resume();
        fixture
            .classify(&["root".into(), "new-root".into(), "child".into()])
            .await;
        let requests = fixture.requests();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0]["threadIds"], json!(["root", "child"]));
        assert_eq!(requests[1]["threadIds"], json!(["new-root"]));
        assert!(requests.iter().all(|request| request["schemaVersion"] == 2));
    }

    #[tokio::test]
    async fn classification_unknown_retries_without_inventing_a_root() {
        let fixture = Fixture::new();
        fixture.state(json!({"unknown":["pending"]}));
        let pending = fixture.classify(&["pending".into()]).await;
        assert_eq!(pending["knownRoots"], json!([]));
        assert_eq!(pending["relations"], json!({}));
        assert_eq!(pending["warnings"], json!(["identityPending"]));
        fixture.state(json!({}));
        assert_eq!(fixture.classify(&["pending".into()]).await, pending);
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(31)).await;
        tokio::time::resume();
        assert_eq!(
            fixture.classify(&["pending".into()]).await["knownRoots"],
            json!(["pending"])
        );
        assert_eq!(fixture.requests().len(), 2);
    }

    #[tokio::test]
    async fn classification_concurrent_refreshes_share_one_launcher_call() {
        let fixture = Fixture::new();
        let ids = vec!["root".into()];
        let (first, second) = tokio::join!(fixture.classify(&ids), fixture.classify(&ids));
        assert_eq!(first, second);
        assert_eq!(fixture.requests().len(), 1);
    }

    #[tokio::test]
    async fn classification_slow_miss_does_not_block_cached_hits_and_shares_its_result() {
        crate::test_support::with_manual_time(async {
            let fixture = Fixture::new();
            let cached = fixture.classify(&["cached".into()]).await;
            fixture.state(json!({"hold":["slow"]}));
            let gateway = fixture.gateway.clone();
            let first = tokio::spawn(async move {
                gateway
                    .agent_service()
                    .agents_rpc(
                        "conversation/agents/classify",
                        json!({"threadIds":["slow"]}),
                    )
                    .await
                    .unwrap()
            });
            fixture.started("slow").await;
            assert_eq!(fixture.classify(&["cached".into()]).await, cached);
            let ids = ["slow".into()];
            let second = fixture.classify(&ids);
            tokio::pin!(second);
            tokio::select! {
                biased;
                _ = &mut second => panic!("shared classification finished before fixture release"),
                () = tokio::task::yield_now() => {}
            }
            tokio::time::advance(Duration::from_millis(2_100)).await;
            tokio::select! {
                biased;
                _ = &mut second => panic!("shared classification expired while its owner remained gated"),
                () = tokio::task::yield_now() => {}
            }
            assert!(!first.is_finished());
            fixture.release();
            let result = first.await.unwrap();
            assert_eq!(result["knownRoots"], json!(["slow"]));
            assert_eq!(second.await, result);
            assert_eq!(fixture.requests().len(), 2);
        })
        .await;
    }

    #[tokio::test]
    async fn classification_cancelled_owner_releases_waiters_and_allows_retry() {
        let fixture = Fixture::new();
        fixture.state(json!({"hold":["held"]}));
        let gateway = fixture.gateway.clone();
        let owner = tokio::spawn(async move {
            gateway
                .agent_service()
                .agents_rpc(
                    "conversation/agents/classify",
                    json!({"threadIds":["held"]}),
                )
                .await
        });
        fixture.started("held").await;
        let gateway = fixture.gateway.clone();
        let waiter = tokio::spawn(async move {
            gateway
                .agent_service()
                .agents_rpc(
                    "conversation/agents/classify",
                    json!({"threadIds":["held"]}),
                )
                .await
                .unwrap()
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let waiting = {
                    let state = fixture.gateway.agents.classifications.state.lock().unwrap();
                    state
                        .pending
                        .values()
                        .any(|pending| pending.receiver_count() == 1)
                };
                if waiting {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        owner.abort();
        assert!(owner.await.unwrap_err().is_cancelled());
        let result = tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result["knownRoots"], json!([]));
        assert_eq!(result["warnings"], json!(["classificationCancelled"]));
        fixture.release();
        fixture.state(json!({}));
        assert_eq!(
            fixture.classify(&["held".into()]).await["knownRoots"],
            json!(["held"])
        );
        assert_eq!(fixture.requests().len(), 2);
    }

    #[tokio::test]
    async fn classification_failed_owner_cleans_up_and_retries_after_negative_expiry() {
        let fixture = Fixture::new();
        fixture.state(json!({"fail":true}));
        let failed = fixture.classify(&["root".into()]).await;
        assert_eq!(failed["knownRoots"], json!([]));
        assert_eq!(failed["warnings"], json!(["launcherUnavailable"]));
        assert!(
            fixture
                .gateway
                .agents
                .classifications
                .state
                .lock()
                .unwrap()
                .pending
                .is_empty()
        );
        fixture.state(json!({}));
        assert_eq!(fixture.classify(&["root".into()]).await, failed);
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(31)).await;
        tokio::time::resume();
        assert_eq!(
            fixture.classify(&["root".into()]).await["knownRoots"],
            json!(["root"])
        );
        assert_eq!(fixture.requests().len(), 2);
    }

    #[test]
    fn classification_pending_bounds_do_not_block_cached_evidence() {
        let classifications = Classifications::default();
        let cached = (PathBuf::from("/fixture"), "cached".to_owned());
        classifications
            .state
            .lock()
            .unwrap()
            .cache
            .insert(cached.clone(), Ancestry::Root)
            .unwrap();
        let subjects: Vec<_> = (0..IN_FLIGHT_LIMIT)
            .map(|index| (PathBuf::from("/fixture"), format!("root-{index}")))
            .collect();
        let owned = classifications.claim(&subjects).unwrap();
        assert!(
            classifications
                .claim(&[(PathBuf::from("/fixture"), "overflow".into())])
                .is_err()
        );
        assert!(classifications.claim(&[cached]).unwrap().waiting.is_empty());
        let readers: Vec<_> = (0..WAITER_LIMIT)
            .map(|_| classifications.claim(&subjects[..1]).unwrap())
            .collect();
        assert!(classifications.claim(&subjects[..1]).is_err());
        drop(readers);
        drop(owned);
        assert!(classifications.claim(&subjects).is_ok());
    }

    #[tokio::test]
    async fn classification_bounds_retention_without_losing_current_response_coverage() {
        let fixture = Fixture::new();
        let ids: Vec<_> = (0..4_200).map(|index| format!("root-{index}")).collect();
        for batch in ids.chunks(200) {
            assert_eq!(
                fixture.classify(batch).await["knownRoots"]
                    .as_array()
                    .unwrap()
                    .len(),
                batch.len()
            );
        }
        fixture
            .classify(&[ids[0].clone(), ids[4_199].clone()])
            .await;
        let requests = fixture.requests();
        assert_eq!(requests.len(), 22);
        assert_eq!(requests.last().unwrap()["threadIds"], json!([ids[0]]));
    }

    #[tokio::test]
    async fn classification_refuses_a_parent_outside_the_host_default_homes() {
        let fixture = Fixture::new();
        fixture.state(json!({"children":{"child":{"kind":"child","parentHome":fixture.directory.path().join("other-codex"),"parentThreadId":"parent","sourceRunId":"child-run"}}}));
        let unknown = fixture.classify(&["child".into()]).await;
        assert_eq!(unknown["knownRoots"], json!([]));
        assert_eq!(unknown["relations"], json!({}));
        assert_eq!(unknown["warnings"], json!(["parentHomeUnavailable"]));
    }

    #[tokio::test]
    #[ignore = "Thirty-minute canonical launcher measurement in a temporary provider home"]
    async fn classification_real_launcher_steady_state_measurement() {
        let source = std::env::var("RC_CLASSIFICATION_PROBE_SCRIPT")
            .expect("Set canonical agent_work.py path");
        let output = PathBuf::from(
            std::env::var("RC_CLASSIFICATION_PROBE_OUTPUT").expect("Set measurement output path"),
        );
        let directory = tempfile::tempdir().unwrap();
        let base = directory.path();
        let program = base.join("agent-work");
        std::fs::write(
            base.join("source.json"),
            serde_json::to_vec(&source).unwrap(),
        )
        .unwrap();
        std::fs::write(&program, r#"#!/usr/bin/env python3
import json,pathlib,sys,uuid
base=pathlib.Path(__file__).parent
source=pathlib.Path(json.loads((base/'source.json').read_text()))
sys.path.insert(0,str(source.parent))
import agent_work
runs=base/'runs'
home=base/'.codex'
if len(sys.argv)>1:
    runs.mkdir()
    sessions=home/'sessions'
    sessions.mkdir(parents=True)
    ids=[str(uuid.UUID(int=index+1)) for index in range(1400)]
    for index,identity in enumerate(ids):
        parent=ids[index%1000] if index>=1000 else None
        run=runs/f'agent-codex-{index:06d}'
        run.mkdir()
        metadata={'agent':'codex','provider_home':str(home),'provider_session_id':identity,
            'parent_kind':'codex' if parent else None,'parent_provider_session_id':parent,
            'parent_home':str(home) if parent else None,'spawned_at_epoch_ms':1,'title':'Fixture',
            'origin_relation':{'kind':'child','parent_kind':'codex','parent_provider_session_id':parent,'parent_home':str(home)} if parent else {'kind':'root'}}
        (run/'metadata.json').write_text(json.dumps(metadata))
        (run/'provider-session.json').write_text(json.dumps({'provider':'codex','session_id':identity}))
        (run/'launch-attempted.json').write_text('{"phase":"launchAttempted"}')
        (run/'done').write_text('exit_code=0\n')
        (sessions/f'rollout-{identity}.jsonl').write_text('')
    for _ in range(100):
        result=agent_work.execute({'schemaVersion':2,'operation':'reindex','limit':500},runs,base)
        if result['coverage']['status']=='complete': break
    else: raise RuntimeError('Fixture index did not become complete')
    print(json.dumps(ids[:30]+ids[1000:1030]))
else:
    request=json.load(sys.stdin)
    version=request.get('schemaVersion',1)
    with (base/f'calls-{version}').open('a') as counter: counter.write('.')
    print(json.dumps(agent_work.execute(request,runs,base)))
"#).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        let seeded = tokio::process::Command::new(&program)
            .arg("seed")
            .output()
            .await
            .unwrap();
        assert!(
            seeded.status.success(),
            "Fixture setup failed: {}",
            String::from_utf8_lossy(&seeded.stderr)
        );
        let ids: Vec<String> = serde_json::from_slice(&seeded.stdout).unwrap();
        let make_gateway = || {
            let gateway = crate::test_support::TestGateway::with_codex(
                std::sync::Arc::new(
                    crate::providers::codex::daemon::CodexAppServer::new_for_test_socket(
                        base.join(".codex"),
                    ),
                ),
                None,
            );
            gateway.use_agent_launcher(program.clone());
            gateway
        };
        let baseline = make_gateway();
        let candidate = make_gateway();
        let start = Instant::now();
        let mut samples = Vec::new();
        for index in 0..90 {
            tokio::time::sleep_until(start + Duration::from_secs(index * 20)).await;
            let began = Instant::now();
            let before = baseline
                .agent_service()
                .launcher_agents(json!({"threadIds":ids}))
                .await
                .unwrap();
            let before_ms = began.elapsed().as_secs_f64() * 1_000.0;
            assert_eq!(before.runs.len(), ids.len());
            let began = Instant::now();
            let after = candidate
                .agent_service()
                .agents_rpc("conversation/agents/classify", json!({"threadIds":ids}))
                .await
                .unwrap();
            let after_ms = began.elapsed().as_secs_f64() * 1_000.0;
            assert_eq!(after["knownRoots"].as_array().unwrap().len(), 30);
            assert_eq!(after["relations"].as_object().unwrap().len(), 30);
            assert_eq!(after["warnings"], json!([]));
            samples.push(json!({"refresh":index,"elapsedSeconds":start.elapsed().as_secs_f64(),"beforeMs":before_ms,"afterMs":after_ms}));
            std::fs::write(
                &output,
                serde_json::to_vec_pretty(&json!({"complete":false,"samples":samples})).unwrap(),
            )
            .unwrap();
        }
        tokio::time::sleep_until(start + Duration::from_secs(1_800)).await;
        let count = |version| {
            std::fs::read(base.join(format!("calls-{version}")))
                .unwrap()
                .len()
        };
        assert_eq!(count(1), 90);
        assert_eq!(count(2), 1);
        std::fs::write(&output, serde_json::to_vec_pretty(&json!({"complete":true,"durationSeconds":start.elapsed().as_secs_f64(),
            "rows":1400,"refreshedRoots":30,"refreshedChildren":30,"beforeSpawns":count(1),"afterSpawns":count(2),"samples":samples})).unwrap()).unwrap();
    }
}
