use super::{
    query::SourceRef,
    store::{ReadControl, Reader},
};
use anyhow::{Context, Result, ensure};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::fs::File;

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
    pub items_cursor: Option<String>,
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
    let row=db.query_row("SELECT s.thread_id,s.provider,i.turn_id,i.kind,i.source_ref,src.local_path,CASE WHEN s.provider='codex' AND i.kind IN ('user','assistant') THEN i.text END FROM item i JOIN session s USING(session_key) JOIN source src USING(source_id) WHERE i.item_key=?1 AND src.present=1",[&request.item_key],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?,r.get::<_,Option<String>>(6)?))).optional()?;
    let (thread_id, provider, turn_id, kind, reference, path, text) =
        row.context("not_found: catalog item is unavailable")?;
    let unique_text = if text.is_some() {
        db.query_row("SELECT count(*)=1 FROM (SELECT 1 FROM item WHERE session_key=(SELECT session_key FROM item WHERE item_key=?1) AND turn_id IS ?2 AND text IS ?3 LIMIT 2)",rusqlite::params![request.item_key,turn_id,text],|r|r.get(0))?
    } else {
        false
    };
    let reference: SourceRef = serde_json::from_str(&reference)?;
    let length = if text.is_some() {
        usize::try_from(reference.length)?
    } else {
        0
    };
    let raw = super::query::verified_item_bytes(
        File::open(path).context("source deleted")?,
        &reference,
        0,
        length,
        || {
            ensure!(!control.stopped(), "locate interrupted");
            Ok(())
        },
    )?;
    let provider_item_id = if length > 0 {
        let record: serde_json::Value = serde_json::from_slice(&raw)?;
        record
            .pointer("/payload/id")
            .and_then(serde_json::Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    } else {
        None
    };
    ensure!(!control.stopped(), "locate interrupted");
    let part = super::item_part(&request.item_key)?;
    Ok(Item {
        response: Response {
            thread_id,
            turn_id: if provider == "codex" { turn_id } else { None },
            turns_cursor: None,
            items_cursor: None,
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
