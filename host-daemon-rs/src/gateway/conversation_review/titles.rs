use super::{Gateway, Outcome, Snapshot, Trace, bounded, effective_title};
use crate::gateway::renames::Candidate;
use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Instant;

pub(super) const THRESHOLD: f64 = 0.60;
pub(super) const MAX_TITLE_CHARACTERS: usize = 80;
const TARGET_TITLE_CHARACTERS: usize = 30;

pub(super) fn eligible(snapshot: &Snapshot) -> bool {
    snapshot.has_user_turn && !snapshot.title.is_empty() && snapshot.latest_user_goal.is_some()
}

pub(super) struct TitleEvaluation {
    pub(super) candidate: Candidate,
    pub(super) permit: tokio::sync::OwnedSemaphorePermit,
}

impl Gateway {
    pub(super) async fn maintain_title(
        self: &Arc<Self>,
        thread: &str,
        turn: &str,
        snapshot: Snapshot,
        trace: &Trace,
        evaluation: TitleEvaluation,
    ) -> Result<Outcome> {
        let latest_user_goal = snapshot
            .latest_user_goal
            .as_deref()
            .context("title goal unavailable")?;
        let question = title_question(&snapshot.title, latest_user_goal);
        let mut title = self
            .ask_title(thread, &question, &snapshot.title, trace)
            .await?;
        trace.event(
            "candidate",
            json!({"oldTitle":snapshot.title,"proposedTitle":title,"attempt":1}),
        );
        if title == snapshot.title {
            trace.event(
                "writerRepair",
                json!({"reason":"writerEchoedRejectedTitle"}),
            );
            let question = title_repair_question(&snapshot.title, latest_user_goal);
            let repaired = self
                .ask_title(thread, &question, &snapshot.title, trace)
                .await?;
            trace.event(
                "candidate",
                json!({"oldTitle":snapshot.title,"proposedTitle":repaired,"attempt":2}),
            );
            if repaired == snapshot.title {
                return Ok(Outcome::kept("writerEchoedRejectedTitleAfterRepair"));
            }
            title = repaired;
        }
        let _admission = self.admission.admit(thread)?;
        if let Some(reason) = self.review_exclusion(thread).await? {
            return Ok(Outcome::skipped(reason));
        }
        trace.event("snapshotStarted", json!({"phase":"revalidation"}));
        let Some(latest) = self.review_snapshot(thread, turn, trace).await? else {
            return Ok(Outcome::skipped("snapshotRejected"));
        };
        let unchanged = latest == snapshot;
        trace.event("revalidation", json!({"unchanged":unchanged,"observedTitle":latest.title,
            "sameTitle":latest.title == snapshot.title,"sameContext":latest.state == snapshot.state}));
        if !unchanged {
            return Ok(Outcome::skipped("snapshotChanged"));
        }
        drop(evaluation.permit);
        self.commit_title(
            thread,
            Some(turn),
            &title,
            &snapshot.title,
            evaluation.candidate,
            trace,
        )
        .await
    }

    pub(super) async fn regenerate_title(
        self: &Arc<Self>,
        thread: &str,
        trace: &Trace,
    ) -> Result<String> {
        let header = self.review_header(thread).await?;
        let header = &header["thread"];
        ensure!(
            header["id"].as_str() == Some(thread) && header["ephemeral"].as_bool() == Some(false),
            "conversation is unavailable"
        );
        let previous = effective_title(header)
            .filter(|title| !title.trim().is_empty())
            .context("the conversation has nothing to name yet")?;
        let candidate = self
            .renames
            .candidate(thread)
            .map_err(|error| anyhow!("rename admission failed: {error:?}"))?;
        let mut title = self
            .ask_title(thread, &requested_title_question(previous), previous, trace)
            .await?;
        trace.event(
            "candidate",
            json!({"oldTitle":previous,"proposedTitle":title,"attempt":1}),
        );
        if title == previous {
            trace.event(
                "writerRepair",
                json!({"reason":"writerEchoedRejectedTitle"}),
            );
            title = self
                .ask_title(
                    thread,
                    &requested_title_repair_question(previous),
                    previous,
                    trace,
                )
                .await?;
            trace.event(
                "candidate",
                json!({"oldTitle":previous,"proposedTitle":title,"attempt":2}),
            );
            ensure!(
                title != previous,
                "the conversation suggested its current name again"
            );
        }
        let outcome = self
            .commit_title(thread, None, &title, previous, candidate, trace)
            .await?;
        ensure!(
            outcome.status == "renamed",
            "the name changed while a new one was being written"
        );
        Ok(title)
    }

    pub(super) async fn commit_title(
        self: &Arc<Self>,
        thread: &str,
        turn: Option<&str>,
        title: &str,
        previous: &str,
        candidate: Candidate,
        trace: &Trace,
    ) -> Result<Outcome> {
        let params = json!({"threadId":thread,"name":title});
        let request = trace.request_id();
        trace.event(
            "renameRequest",
            json!({"requestId":request,"method":"thread/name/set","params":params}),
        );
        let started = Instant::now();
        let result = self
            .rename_automatically(thread, title, previous, candidate)
            .await;
        match result {
            Ok(None) => return Ok(Outcome::skipped("manualRenameOrTitleChanged")),
            Ok(Some(response)) => trace.event(
                "renameResponse",
                json!({"requestId":request,"result":response,
                "elapsedMs":started.elapsed().as_secs_f64()*1000.0}),
            ),
            Err(error) => {
                trace.event(
                    "renameFailed",
                    json!({"requestId":request,"error":format!("{error:#}"),
                    "elapsedMs":started.elapsed().as_secs_f64()*1000.0}),
                );
                return Err(error);
            }
        }
        match self.review_header(thread).await {
            Ok(header) => trace.event(
                "renameReadback",
                json!({"observedTitle":header["thread"]["name"],
                "matches":header["thread"]["name"].as_str().map(|actual| actual == title)}),
            ),
            Err(error) => trace.event(
                "renameReadbackFailed",
                json!({"error":format!("{error:#}")}),
            ),
        }
        trace.event("renamed", json!({"oldTitle":previous,"newTitle":title}));
        self.journal.push(
            "conversationTitleUpdated",
            json!({"threadId":thread,"turnId":turn}),
        );
        Ok(Outcome {
            status: "renamed",
            reason: "renameAcknowledged",
        })
    }

    pub(super) async fn ask_title(
        &self,
        thread: &str,
        question: &str,
        rejected_title: &str,
        trace: &Trace,
    ) -> Result<String> {
        trace.event("sideQuestion", json!({"question":question}));
        let started = Instant::now();
        let answer = self.side_question(thread, question).await?;
        trace.event(
            "sideAnswer",
            json!({"answer":answer.text,"usage":answer.usage,
            "elapsedMs":started.elapsed().as_secs_f64()*1000.0}),
        );
        let title = normalized_title(&answer.text);
        if title == rejected_title {
            Ok(title.to_owned())
        } else {
            valid_title(title)
        }
    }
}
fn title_question(current: &str, latest_user_goal: &str) -> String {
    format!(
        "Suggest a better title for this conversation; the current one, “{}”, no longer fits. \
         Reply with only the title: one line, at most {TARGET_TITLE_CHARACTERS} characters, naming \
         the current task, in the conversation's language. Do not use tools. \
         Prioritize this frozen latest user request over the inherited opening topic, \
         using earlier context only to resolve references:\n{}",
        bounded(current, 256),
        json!(latest_user_goal)
    )
}

pub(super) fn early_title_question() -> String {
    format!(
        "Suggest a title for this conversation in a conversation list. Reply with only the title: \
         one line, at most {TARGET_TITLE_CHARACTERS} characters, naming the task as it is now understood, \
         in the conversation's language. Do not use tools. The work may still be in progress; \
         title the task, not its progress."
    )
}

fn requested_title_question(current: &str) -> String {
    format!(
        "The user asked for a new title for this conversation to replace “{}”. Reply with only \
         the title: one line, at most {TARGET_TITLE_CHARACTERS} characters, naming the \
         conversation's current task, in the conversation's language. Do not use tools.",
        bounded(current, 256)
    )
}

fn requested_title_repair_question(current: &str) -> String {
    format!(
        "{}\nYour first answer repeated the current title. Return a different title.",
        requested_title_question(current)
    )
}

fn title_repair_question(current: &str, latest_user_goal: &str) -> String {
    format!(
        "{}\nYour first answer repeated the rejected title. Return a different title that names the latest user task; repeating the old title is not a repair.",
        title_question(current, latest_user_goal)
    )
}

fn normalized_title(answer: &str) -> &str {
    answer.trim().trim_matches(['"', '“', '”']).trim()
}

pub(super) fn valid_title(answer: &str) -> Result<String> {
    let title = normalized_title(answer);
    ensure!(
        !title.is_empty()
            && title.chars().count() <= MAX_TITLE_CHARACTERS
            && !title.chars().any(char::is_control)
            && !title.contains('`'),
        "invalid generated title"
    );
    Ok(title.to_owned())
}

pub(super) fn decision(
    state: &Value,
    response: &Value,
) -> Result<(bool, Value, Vec<&'static str>)> {
    let mut probabilities = serde_json::Map::new();
    let mut triggers = Vec::new();
    if state["titleTooLong"].as_bool() == Some(true) {
        triggers.push("titleTooLong");
    }
    for id in ["misleading", "vague", "unsuitable"] {
        let answer = &response["answers"][id];
        ensure!(answer["type"] == "noul", "invalid title decision type");
        let probability = answer["noul"].as_f64().context("missing title decision")?;
        ensure!(
            probability.is_finite() && (0.0..=1.0).contains(&probability),
            "invalid title decision"
        );
        probabilities.insert(id.into(), json!(probability));
        if probability >= THRESHOLD {
            triggers.push(id);
        }
    }
    let rename = !triggers.is_empty();
    Ok((rename, json!(probabilities), triggers))
}
