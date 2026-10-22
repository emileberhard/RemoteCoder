//! Resumable native pages. Cursors remain opaque, and source anchors are verified.
use std::collections::BTreeMap;
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use super::Gateway;
use crate::questions::{Anchor, Document, Entry, Facts, Scan, normalize, relevant};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    data: Vec<Entry>,
    next_cursor: Option<String>,
}

pub(super) async fn reconstruct(
    gateway: &Arc<Gateway>,
    thread: &str,
    owner: &str,
    checkpoint: Option<&Value>,
) -> Result<Document> {
    let current = gateway.questions.store.read(thread).await?;
    let frozen = checkpoint
        .and_then(|checkpoint| checkpoint["itemsBackwardsCursor"].as_str())
        .map(str::to_owned);
    let resumed = current.scan.is_some();
    let mut scan = current
        .scan
        .clone()
        .unwrap_or_else(|| begin(&current, frozen.clone()));
    scan = read_pages(gateway, thread, owner, scan).await?;
    if resumed {
        // The resumed cursor still belongs to its OLD frozen boundary. A fresh
        // checkpoint must cover the interval traversed while that scan was absent.
        let baseline = DocumentBaseline {
            facts: scan.facts,
            anchor: scan.anchor,
            incomplete: scan.incomplete,
        };
        scan = begin_baseline(baseline, frozen, scan.lineage_changed);
        scan = read_pages(gateway, thread, owner, scan).await?;
    }
    let owner = owner.to_owned();
    gateway
        .questions
        .store
        .transaction(thread, move |document| {
            ensure!(
                document.writer.as_deref() == Some(&owner),
                "question reconstruction superseded"
            );
            if scan.lineage_changed {
                document.reset_lineage()?;
            }
            document.replace_facts(scan.facts, scan.anchor, scan.incomplete)?;
            document.scan = None;
            document.revision = document
                .revision
                .checked_add(1)
                .context("question revision exhausted")?;
            Ok(document.clone())
        })
        .await
}

struct DocumentBaseline {
    facts: Facts,
    anchor: Option<Anchor>,
    incomplete: BTreeMap<String, i64>,
}

fn begin(document: &Document, cursor: Option<String>) -> Scan {
    begin_baseline(
        DocumentBaseline {
            facts: document.facts.clone(),
            anchor: document.anchor.clone(),
            incomplete: document.incomplete.clone(),
        },
        cursor,
        false,
    )
}

fn begin_baseline(
    baseline: DocumentBaseline,
    cursor: Option<String>,
    lineage_changed: bool,
) -> Scan {
    let minimum_ordinal = baseline
        .incomplete
        .values()
        .copied()
        .chain(baseline.anchor.as_ref().map(|anchor| anchor.ordinal))
        .min();
    Scan {
        cursor: cursor.clone(),
        initial_cursor: cursor,
        floor: baseline.anchor,
        floor_found: false,
        minimum_ordinal,
        complete: false,
        lineage_changed,
        facts: baseline.facts,
        anchor: None,
        incomplete: baseline.incomplete,
    }
}

async fn read_pages(
    gateway: &Arc<Gateway>,
    thread: &str,
    owner: &str,
    mut scan: Scan,
) -> Result<Scan> {
    let mut resets = 0;
    while !scan.complete {
        let mut request = json!({"threadId":thread,"limit":50,"sortDirection":"desc"});
        if let Some(cursor) = &scan.cursor {
            request["cursor"] = json!(cursor);
        }
        let response = gateway.call_control("thread/items/list", request).await?;
        let page: Page =
            serde_json::from_value(response).context("invalid native question history page")?;
        ensure!(
            page.data.len() <= 50,
            "native history exceeded requested page capacity"
        );
        let previous_cursor = scan.cursor.clone();
        let mut crossed_floor = false;
        let mut reached_minimum = false;
        for entry in page.data {
            let ordinal = entry
                .started_at_ordinal
                .context("native history lacks canonical positions")?;
            let id = entry.item["id"]
                .as_str()
                .context("native history item has no identity")?
                .to_owned();
            if scan
                .anchor
                .as_ref()
                .is_none_or(|anchor| ordinal > anchor.ordinal)
            {
                scan.anchor = Some(Anchor {
                    item_id: id.clone(),
                    ordinal,
                });
            }
            if let Some(floor) = &scan.floor {
                if ordinal == floor.ordinal && id == floor.item_id {
                    scan.floor_found = true;
                }
                if ordinal <= floor.ordinal && !scan.floor_found {
                    crossed_floor = true;
                }
            }
            reached_minimum |= scan
                .minimum_ordinal
                .is_some_and(|minimum| ordinal <= minimum);
            if relevant(&entry.item) {
                if entry.is_complete == Some(true) {
                    scan.incomplete.remove(&id);
                } else {
                    scan.incomplete.insert(id, ordinal);
                }
                if let Some(fact) = normalize(&entry)? {
                    scan.facts.apply(fact)?;
                }
            }
        }
        if scan.floor.is_some()
            && !scan.floor_found
            && (crossed_floor || page.next_cursor.is_none())
        {
            ensure!(
                resets == 0,
                "native history changed repeatedly during question reconstruction"
            );
            resets += 1;
            // Revert/fork lineage changed below the retained boundary. Never merge
            // old answers into the replacement history or manufacture continuity.
            scan = begin_baseline(
                DocumentBaseline {
                    facts: Facts::default(),
                    anchor: None,
                    incomplete: BTreeMap::new(),
                },
                scan.initial_cursor,
                true,
            );
        } else {
            scan.complete = page.next_cursor.is_none() || scan.floor_found && reached_minimum;
            if !scan.complete {
                ensure!(
                    page.next_cursor != previous_cursor,
                    "native history cursor did not advance"
                );
            }
            scan.cursor = page.next_cursor;
        }
        let staged = scan.clone();
        let owner = owner.to_owned();
        gateway
            .questions
            .store
            .transaction(thread, move |document| {
                ensure!(
                    document.writer.as_deref() == Some(&owner),
                    "question page writer superseded"
                );
                document.scan = Some(staged);
                Ok(())
            })
            .await?;
    }
    Ok(scan)
}
