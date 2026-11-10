use super::{
    query::SessionHeader,
    store::{ReadControl, Reader},
};
use anyhow::{Result, ensure};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(crate) const DEADLINE: Duration = Duration::from_secs(1);
pub(super) const TERM_WINDOW: usize = 512;
const HEADER_LIMIT: usize = 10_000;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    pub query: String,
    pub limit: usize,
}

impl Request {
    pub(crate) fn terms(&self) -> Result<Vec<String>> {
        let query = self.query.trim();
        ensure!(
            (1..=512).contains(&query.len()),
            "query must be 1..=512 UTF-8 bytes after trimming"
        );
        ensure!((1..=50).contains(&self.limit), "limit must be 1..=50");
        let mut terms = Vec::new();
        for word in query.split_whitespace() {
            let word = word.to_lowercase();
            if !terms.contains(&word) {
                terms.push(word);
            }
        }
        ensure!(terms.len() <= 8, "query accepts at most 8 distinct terms");
        Ok(terms)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Response {
    pub schema_version: u32,
    pub truncated: bool,
    pub conversations: Vec<Conversation>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Conversation {
    pub session_key: String,
    pub host_id: String,
    pub provider: String,
    pub thread_id: String,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub last_at: Option<String>,
    pub title_match: bool,
    pub hit_count: usize,
    pub hits: Vec<Hit>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Hit {
    pub item_key: String,
    pub kind: String,
    pub at: Option<String>,
    pub excerpt: String,
    pub agent_thread_id: Option<String>,
}

pub(crate) type Completed = Arc<Mutex<Option<Response>>>;
pub(crate) struct Header {
    pub session: SessionHeader,
    pub provider_home: String,
}

struct Item {
    session_key: String,
    hit: Hit,
    terms: u8,
}

struct Group<'a> {
    header: &'a SessionHeader,
    terms: u8,
    title_match: bool,
    newest: Option<&'a str>,
    items: Vec<&'a Item>,
}

pub(crate) fn partial(completed: &Completed) -> Option<Response> {
    completed
        .lock()
        .expect("conversation search progress poisoned")
        .clone()
        .map(|mut response| {
            response.truncated = true;
            response
        })
}

pub(crate) fn search(
    db: &Reader,
    request: &Request,
    control: &ReadControl,
    parents: impl FnOnce(&[Header]) -> HashMap<String, Option<String>>,
    completed: &Completed,
) -> Result<Response> {
    let terms = request.terms()?;
    let message_mask = terms.iter().enumerate().fold(0, |bits, (index, term)| {
        bits | if term.chars().count() >= 3 {
            1 << index
        } else {
            0
        }
    });
    let run = || -> Result<Response> {
        let mut statement = db.prepare("SELECT s.session_key,s.origin_host,s.provider,s.thread_id,s.cwd,s.title,s.started_at,s.last_at,s.parent_session_key,src.present,s.provider_home FROM session s JOIN source src USING(source_id) ORDER BY s.last_at DESC,s.session_key LIMIT ?1")?;
        let mut rows = statement.query([HEADER_LIMIT as i64 + 1])?;
        let mut headers = Vec::new();
        let mut truncated = false;
        while let Some(row) = rows.next()? {
            if headers.len() == HEADER_LIMIT {
                truncated = true;
                break;
            }
            headers.push(Header {
                session: super::query::session_header(row)?,
                provider_home: row.get(10)?,
            });
            ensure!(!control.stopped(), "conversation search interrupted");
        }
        drop(rows);
        drop(statement);
        let delegated = parents(&headers);
        let headers: HashMap<_, _> = headers
            .into_iter()
            .map(|h| (h.session.session_key.clone(), h.session))
            .collect();
        let mut items = HashMap::new();
        let mut response = rank(
            &headers,
            &delegated,
            &items,
            &terms,
            request.limit,
            truncated,
        );
        *completed
            .lock()
            .expect("conversation search progress poisoned") = Some(response.clone());
        for term in terms.iter().filter(|t| t.chars().count() >= 3) {
            ensure!(!control.stopped(), "conversation search interrupted");
            let literal = format!("\"{}\"", term.replace('"', "\"\""));
            let mut statement = db.prepare("SELECT i.item_key,i.session_key,i.kind,i.at,i.text FROM item_fts CROSS JOIN item i ON i.rowid=item_fts.rowid WHERE item_fts MATCH ?1 ORDER BY item_fts.rowid DESC LIMIT ?2")?;
            let mut rows = statement.query(params![literal, TERM_WINDOW as i64 + 1])?;
            let mut stage = Vec::new();
            while let Some(row) = rows.next()? {
                if stage.len() == TERM_WINDOW {
                    truncated = true;
                    break;
                }
                let text: String = row.get(4)?;
                let lowered = text.to_lowercase();
                let matches = mask(&lowered, &terms) & message_mask;
                let excerpt = excerpt(&text, &lowered, &terms, matches);
                stage.push(Item {
                    session_key: row.get(1)?,
                    terms: matches,
                    hit: Hit {
                        item_key: row.get(0)?,
                        kind: row.get(2)?,
                        at: row.get(3)?,
                        excerpt,
                        agent_thread_id: None,
                    },
                });
                ensure!(!control.stopped(), "conversation search interrupted");
            }
            for item in stage {
                items.insert(item.hit.item_key.clone(), item);
            }
            response = rank(
                &headers,
                &delegated,
                &items,
                &terms,
                request.limit,
                truncated,
            );
            *completed
                .lock()
                .expect("conversation search progress poisoned") = Some(response.clone());
        }
        Ok(response)
    };
    match run() {
        Err(_) if control.stopped() => {
            partial(completed).ok_or_else(|| anyhow::anyhow!("conversation search timed out"))
        }
        result => result,
    }
}

fn mask(text: &str, terms: &[String]) -> u8 {
    terms.iter().enumerate().fold(0, |mask, (index, term)| {
        mask | if text.contains(term) { 1 << index } else { 0 }
    })
}

fn metadata(header: &SessionHeader, terms: &[String]) -> u8 {
    mask(&header.title.as_deref().unwrap_or("").to_lowercase(), terms)
        | mask(&header.cwd.as_deref().unwrap_or("").to_lowercase(), terms)
}

fn root<'a>(
    key: &'a str,
    headers: &'a HashMap<String, SessionHeader>,
    delegated: &'a HashMap<String, Option<String>>,
) -> &'a str {
    let mut current = key;
    let mut visited = HashSet::new();
    for _ in 0..16 {
        if !visited.insert(current) {
            return key;
        }
        let Some(header) = headers.get(current) else {
            return key;
        };
        let next = match delegated.get(current) {
            Some(parent) => parent.as_deref(),
            None => header.parent_session_key.as_deref(),
        };
        match next {
            Some(parent) if headers.contains_key(parent) => current = parent,
            Some(_) => return key,
            None => return current,
        }
    }
    key
}

fn rank(
    headers: &HashMap<String, SessionHeader>,
    delegated: &HashMap<String, Option<String>>,
    items: &HashMap<String, Item>,
    terms: &[String],
    limit: usize,
    truncated: bool,
) -> Response {
    let mut groups: HashMap<&str, Group<'_>> = HashMap::new();
    let all_terms = ((1u16 << terms.len()) - 1) as u8;
    for (key, item) in headers
        .values()
        .map(|header| (header.session_key.as_str(), None))
        .chain(
            items
                .values()
                .map(|item| (item.session_key.as_str(), Some(item))),
        )
    {
        let Some(header) = headers.get(key).filter(|h| h.source_present) else {
            continue;
        };
        let covered = metadata(header, terms) | item.map_or(0, |i| i.terms);
        if covered == 0 {
            continue;
        }
        let key = root(&header.session_key, headers, delegated);
        let Some(header) = headers.get(key).filter(|h| h.source_present) else {
            continue;
        };
        let entry = groups.entry(key).or_insert_with(|| Group {
            header,
            terms: metadata(header, terms),
            title_match: header
                .title
                .as_ref()
                .is_some_and(|t| mask(&t.to_lowercase(), terms) == all_terms),
            newest: None,
            items: Vec::new(),
        });
        entry.terms |= covered;
        if let Some(item) = item {
            entry.newest = entry.newest.max(item.hit.at.as_deref());
            entry.items.push(item);
        }
    }
    let mut groups: Vec<_> = groups.into_values().collect();
    groups.sort_by(|a, b| {
        b.terms
            .count_ones()
            .cmp(&a.terms.count_ones())
            .then_with(|| b.title_match.cmp(&a.title_match))
            .then_with(|| {
                b.newest
                    .or(b.header.last_at.as_deref())
                    .cmp(&a.newest.or(a.header.last_at.as_deref()))
            })
            .then_with(|| a.header.session_key.cmp(&b.header.session_key))
    });
    let conversations = groups
        .into_iter()
        .take(limit)
        .map(|mut group| {
            group.items.sort_by(|a, b| {
                b.terms
                    .count_ones()
                    .cmp(&a.terms.count_ones())
                    .then_with(|| text_kind(&b.hit.kind).cmp(&text_kind(&a.hit.kind)))
                    .then_with(|| b.hit.at.cmp(&a.hit.at))
                    .then_with(|| a.hit.item_key.cmp(&b.hit.item_key))
            });
            Conversation {
                session_key: group.header.session_key.clone(),
                host_id: group.header.host_id.clone(),
                provider: group.header.provider.clone(),
                thread_id: group.header.thread_id.clone(),
                title: group.header.title.clone(),
                cwd: group.header.cwd.clone(),
                last_at: group.header.last_at.clone(),
                title_match: group.title_match,
                hit_count: group.items.len(),
                hits: group
                    .items
                    .into_iter()
                    .take(3)
                    .map(|item| {
                        let mut hit = item.hit.clone();
                        if item.session_key != group.header.session_key {
                            hit.agent_thread_id =
                                headers.get(&item.session_key).map(|h| h.thread_id.clone());
                        }
                        hit
                    })
                    .collect(),
            }
        })
        .collect();
    Response {
        schema_version: 1,
        truncated,
        conversations,
    }
}

fn text_kind(kind: &str) -> bool {
    matches!(kind, "user" | "assistant")
}

fn excerpt(text: &str, lowered: &str, terms: &[String], matches: u8) -> String {
    let first_byte = terms
        .iter()
        .enumerate()
        .filter(|(index, _)| matches & (1 << index) != 0)
        .filter_map(|(_, term)| lowered.find(term))
        .min()
        .unwrap_or(0);
    let mut bytes = 0;
    let first = text
        .chars()
        .take_while(|character| {
            bytes += character.to_lowercase().map(char::len_utf8).sum::<usize>();
            bytes <= first_byte
        })
        .count();
    let length = text.chars().count();
    let start = first.saturating_sub(119).min(length.saturating_sub(238));
    let end = (start + 238).min(length);
    let mut result = String::new();
    if start > 0 {
        result.push('…');
    }
    result.extend(text.chars().skip(start).take(end - start));
    if end < length {
        result.push('…');
    }
    result
}
