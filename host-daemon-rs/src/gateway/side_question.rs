use super::Gateway;
use crate::notifications::notification_thread_id;
use crate::providers::claude::is_claude_thread_id;
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::warn;

const FORK_ANSWER_TIMEOUT: Duration = Duration::from_secs(60);
const FORK_EVENT_CAPACITY: usize = 64;
const RETIRED_FORKS: usize = 16;

#[derive(Default)]
pub(super) struct Forks(Mutex<Registry>);

#[derive(Default)]
struct Registry {
    parents: Vec<String>,
    live: HashMap<String, mpsc::Sender<Value>>,
    retired: VecDeque<String>,
}

impl Registry {
    fn owner(&self, message: &Value) -> Option<String> {
        let thread = notification_thread_id(message)?;
        let started = &message["params"]["thread"];
        let claimed = message["method"] == "thread/started"
            && started["ephemeral"] == true
            && started["forkedFromId"]
                .as_str()
                .is_some_and(|parent| self.parents.iter().any(|claimed| claimed == parent));
        (claimed || self.live.contains_key(&thread) || self.retired.contains(&thread))
            .then_some(thread)
    }
}

struct Claim<'a> {
    forks: &'a Forks,
    parent: String,
    fork: Option<String>,
}

impl Claim<'_> {
    fn attach(&mut self, fork: &str) -> mpsc::Receiver<Value> {
        let (sender, receiver) = mpsc::channel(FORK_EVENT_CAPACITY);
        self.forks.registry().live.insert(fork.to_owned(), sender);
        self.fork = Some(fork.to_owned());
        receiver
    }
}

impl Drop for Claim<'_> {
    fn drop(&mut self) {
        let mut registry = self.forks.registry();
        if let Some(index) = registry
            .parents
            .iter()
            .position(|parent| parent == &self.parent)
        {
            registry.parents.swap_remove(index);
        }
        if let Some(fork) = self.fork.take()
            && registry.live.remove(&fork).is_some()
        {
            if registry.retired.len() == RETIRED_FORKS {
                registry.retired.pop_front();
            }
            registry.retired.push_back(fork);
        }
    }
}

impl Forks {
    fn registry(&self) -> std::sync::MutexGuard<'_, Registry> {
        self.0.lock().expect("side question forks poisoned")
    }

    fn claim(&self, parent: &str) -> Claim<'_> {
        self.registry().parents.push(parent.to_owned());
        Claim {
            forks: self,
            parent: parent.to_owned(),
            fork: None,
        }
    }

    pub(super) fn owns(&self, message: &Value) -> bool {
        self.registry().owner(message).is_some()
    }

    pub(super) fn owns_thread(&self, thread: &str) -> bool {
        let registry = self.registry();
        registry.live.contains_key(thread) || registry.retired.iter().any(|fork| fork == thread)
    }

    pub(super) fn route(&self, message: &Value) -> bool {
        let registry = self.registry();
        let Some(thread) = registry.owner(message) else {
            return false;
        };
        if let Some(events) = registry.live.get(&thread)
            && (message.get("id").is_some()
                || matches!(
                    message["method"].as_str(),
                    Some(
                        "item/started"
                            | "item/completed"
                            | "thread/tokenUsage/updated"
                            | "turn/completed"
                    )
                ))
        {
            let _ = events.try_send(message.clone());
        }
        true
    }
}

pub(super) struct SideAnswer {
    pub(super) text: String,
    pub(super) usage: Value,
}

impl Gateway {
    pub(super) async fn side_question(&self, thread: &str, question: &str) -> Result<SideAnswer> {
        if !is_claude_thread_id(thread) {
            return self.codex_side_question(thread, question).await;
        }
        let agent = self.claude_agent().context("Claude is unavailable")?;
        let warm = agent
            .side_question(thread, question)
            .await
            .map_err(|error| anyhow!("Claude side question failed: {error}"))?;
        let text = match warm {
            Some(text) => text,
            None => {
                let header = self.review_header(thread).await?;
                let cwd = header["thread"]["cwd"]
                    .as_str()
                    .context("Claude conversation has no working directory")?;
                agent
                    .detached_side_question(thread, cwd, question)
                    .await
                    .map_err(|error| anyhow!("Claude side question failed: {error}"))?
            }
        };
        Ok(SideAnswer {
            text,
            usage: Value::Null,
        })
    }

    async fn codex_side_question(&self, thread: &str, question: &str) -> Result<SideAnswer> {
        let parent = self
            .call_control(
                "thread/read",
                json!({"threadId":thread,"includeTurns":false}),
            )
            .await?;
        let parent = &parent["thread"];
        let mut claim = self.side_question_forks.claim(thread);
        let fork = self
            .call_control(
                "thread/fork",
                json!({"threadId":thread,"ephemeral":true,"excludeTurns":true,
                    "model":parent["model"],"sandbox":"read-only","approvalPolicy":"never"}),
            )
            .await?;
        let ephemeral = fork["thread"]["ephemeral"] == true;
        let fork = fork["thread"]["id"]
            .as_str()
            .context("Codex returned no side-question fork")?
            .to_owned();
        let mut events = claim.attach(&fork);
        let answer = if ephemeral {
            self.ask_fork(&fork, question, &parent["reasoningEffort"], &mut events)
                .await
        } else {
            Err(anyhow!(
                "Codex did not return an ephemeral side-question fork"
            ))
        };
        let unsubscribed = self
            .call_control("thread/unsubscribe", json!({"threadId":fork}))
            .await;
        drop(claim);
        if let Err(error) = unsubscribed {
            warn!(fork, "side-question fork unsubscribe failed: {error:#}");
        }
        answer
    }

    async fn ask_fork(
        &self,
        fork: &str,
        question: &str,
        effort: &Value,
        events: &mut mpsc::Receiver<Value>,
    ) -> Result<SideAnswer> {
        let started = self
            .call_control(
                "turn/start",
                json!({"threadId":fork,"effort":effort,
                    "input":[{"type":"text","text":question,"text_elements":[]}]}),
            )
            .await?;
        let turn = started["turn"]["id"]
            .as_str()
            .context("Codex did not return the side-question turn")?;
        let answer = tokio::time::timeout(FORK_ANSWER_TIMEOUT, fork_answer(events))
            .await
            .unwrap_or_else(|_| Err(anyhow!("side-question fork timed out")));
        if answer.is_err() {
            let _ = self
                .call_control("turn/interrupt", json!({"threadId":fork,"turnId":turn}))
                .await;
        }
        answer
    }
}

async fn fork_answer(events: &mut mpsc::Receiver<Value>) -> Result<SideAnswer> {
    let mut answer = None;
    let mut usage = Value::Null;
    while let Some(event) = events.recv().await {
        if event.get("id").is_some() {
            bail!("side-question fork asked for {}", event["method"]);
        }
        let item = &event["params"]["item"];
        match event["method"].as_str() {
            Some("item/started") => ensure!(
                matches!(
                    item["type"].as_str(),
                    Some("userMessage" | "agentMessage" | "reasoning")
                ),
                "side-question fork started {}",
                item["type"]
            ),
            Some("item/completed") if item["type"] == "agentMessage" => {
                answer = item["text"].as_str().map(str::to_owned);
            }
            Some("thread/tokenUsage/updated") => {
                usage = event["params"]["tokenUsage"]["last"].clone();
            }
            Some("turn/completed") => {
                let turn = &event["params"]["turn"];
                ensure!(
                    turn["status"] == "completed",
                    "side-question fork ended {}: {}",
                    turn["status"],
                    turn["error"]
                );
                let text = answer.context("side-question fork gave no answer")?;
                return Ok(SideAnswer { text, usage });
            }
            _ => {}
        }
    }
    bail!("side-question fork events ended")
}
