use super::titles::early_title_question;
use super::{Gateway, Outcome, Trace, effective_title};
use anyhow::Result;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

pub(super) const DELAY: Duration = Duration::from_secs(15);
pub(super) const MAX_PENDING: usize = 32;

impl Gateway {
    pub(super) async fn early_title(self: &Arc<Self>, thread: &str, turn: &str) -> Result<()> {
        if !self.may_be_first_turn(thread, turn).await.unwrap_or(true) {
            return Ok(());
        }
        tokio::time::sleep(DELAY).await;
        let header = self.review_header(thread).await?;
        let header = &header["thread"];
        if !untitled(header, thread) {
            return Ok(());
        }
        let turns = self.review_turns(thread, "desc", 2).await?;
        let Some([first]) = turns["data"].as_array().map(Vec::as_slice) else {
            return Ok(());
        };
        if first["id"].as_str() != Some(turn)
            || first["status"] != "inProgress"
            || !has_user_message(first)
        {
            return Ok(());
        }
        let previous = effective_title(header).unwrap_or_default();
        let mut trace = self.early_title_trace(thread, turn);
        trace.event(
            "header",
            json!({"status":header["status"],"preview":header["preview"],"turnStatus":first["status"]}),
        );
        match self.write_early_title(thread, turn, previous, &trace).await {
            Ok(outcome) => trace.finish(outcome.status, outcome.reason),
            Err(error) => trace.failed(&error),
        }
        Ok(())
    }

    async fn may_be_first_turn(&self, thread: &str, turn: &str) -> Result<bool> {
        let header = self.review_header(thread).await?;
        if !untitled(&header["thread"], thread) {
            return Ok(false);
        }
        let turns = self.review_turns(thread, "desc", 2).await?;
        Ok(match turns["data"].as_array().map(Vec::as_slice) {
            Some([]) => true,
            Some([only]) => only["id"].as_str() == Some(turn),
            _ => false,
        })
    }

    async fn write_early_title(
        self: &Arc<Self>,
        thread: &str,
        turn: &str,
        previous: &str,
        trace: &Trace,
    ) -> Result<Outcome> {
        if let Some(reason) = self.review_exclusion(thread).await? {
            return Ok(Outcome::skipped(reason));
        }
        if self.is_agent_thread(thread).await? {
            return Ok(Outcome::skipped("delegatedAgent"));
        }
        let candidate = self
            .renames
            .candidate(thread)
            .map_err(|error| anyhow::anyhow!("rename admission failed: {error:?}"))?;
        let title = self
            .ask_title(thread, &early_title_question(), previous, trace)
            .await?;
        trace.event(
            "candidate",
            json!({"oldTitle":previous,"proposedTitle":title,"attempt":1}),
        );
        if title == previous {
            return Ok(Outcome::kept("writerKeptTitle"));
        }
        let _admission = self.admission.admit(thread)?;
        if let Some(reason) = self.review_exclusion(thread).await? {
            return Ok(Outcome::skipped(reason));
        }
        self.commit_title(thread, Some(turn), &title, previous, candidate, trace)
            .await
    }
}

fn untitled(header: &Value, thread: &str) -> bool {
    header["id"].as_str() == Some(thread)
        && header["ephemeral"].as_bool() == Some(false)
        && header["name"]
            .as_str()
            .is_none_or(|name| name.trim().is_empty())
}

fn has_user_message(turn: &Value) -> bool {
    turn["items"]
        .as_array()
        .is_some_and(|items| items.iter().any(|item| item["type"] == "userMessage"))
}
