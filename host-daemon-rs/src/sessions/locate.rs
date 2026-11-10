use super::{
    query::SourceRef,
    store::{ReadControl, Reader},
};
use anyhow::{Context, Result, ensure};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::time::Duration;

pub(crate) const DEADLINE: Duration = Duration::from_secs(1);

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    pub item_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Response {
    pub thread_id: String,
    pub turn_id: Option<String>,
    pub turns_cursor: Option<String>,
    pub item_id: Option<String>,
}

pub(crate) struct Item {
    pub response: Response,
    pub provider: String,
    pub kind: String,
    pub reference: SourceRef,
    pub part: usize,
    pub text: Option<String>,
    pub provider_item_id: Option<String>,
    pub unique_text: bool,
}

pub(crate) fn item(db: &Reader, request: &Request, control: &ReadControl) -> Result<Item> {
    ensure!(!control.stopped(), "locate interrupted");
    let row:Option<(String,String,Option<String>,String,String,String,Option<String>)>=db.query_row("SELECT s.thread_id,s.provider,i.turn_id,i.kind,i.source_ref,src.local_path,i.text FROM item i JOIN session s USING(session_key) JOIN source src USING(source_id) WHERE i.item_key=?1 AND src.present=1",[&request.item_key],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional()?;
    let (thread_id, provider, turn_id, kind, reference, path, text) =
        row.context("not_found: catalog item is unavailable")?;
    let unique_text = if provider == "codex" {
        db.query_row("SELECT count(*)=1 FROM (SELECT 1 FROM item WHERE session_key=(SELECT session_key FROM item WHERE item_key=?1) AND turn_id IS ?2 AND text IS ?3 LIMIT 2)",rusqlite::params![request.item_key,turn_id,text],|r|r.get(0))?
    } else {
        false
    };
    let reference: SourceRef = serde_json::from_str(&reference)?;
    let raw = super::query::item_bytes(
        File::open(path).context("source deleted")?,
        &reference,
        0,
        usize::try_from(reference.length)?,
    )?;
    let record: serde_json::Value = serde_json::from_slice(&raw)?;
    ensure!(!control.stopped(), "locate interrupted");
    let provider_item_id = record
        .pointer("/payload/id")
        .and_then(serde_json::Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let part = request
        .item_key
        .rsplit_once(':')
        .context("Invalid item key")?
        .1
        .parse()?;
    Ok(Item {
        response: Response {
            thread_id,
            turn_id: if provider == "codex" { turn_id } else { None },
            turns_cursor: None,
            item_id: None,
        },
        provider,
        kind,
        reference,
        part,
        text,
        provider_item_id,
        unique_text,
    })
}

pub(crate) fn item_text(item: &serde_json::Value) -> Option<String> {
    if let Some(text) = item["text"].as_str() {
        return Some(text.to_owned());
    }
    let content = item["content"].as_array()?;
    Some(
        content
            .iter()
            .filter(|p| p["type"] == "text")
            .filter_map(|p| p["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
    )
}
