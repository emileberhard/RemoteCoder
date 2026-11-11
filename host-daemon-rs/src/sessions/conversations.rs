use super::store::{ReadControl, Reader};
use anyhow::{Result, ensure};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

pub(crate) const DEADLINE: Duration = Duration::from_secs(1);
pub(super) const TERM_WINDOW: usize = 64;
const EXCERPT_INPUT_BYTES: i64 = 1 << 20;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    pub query: String,
    pub limit: usize,
}

impl Request {
    pub(crate) fn validate(&self) -> Result<()> {
        let query = self.query.trim();
        ensure!(
            (1..=512).contains(&query.len()),
            "query must be 1..=512 UTF-8 bytes after trimming"
        );
        ensure!((1..=50).contains(&self.limit), "limit must be 1..=50");
        Ok(())
    }

    pub(crate) fn terms(&self) -> Result<Vec<String>> {
        self.validate()?;
        let query = self.query.trim();
        let mut terms = Vec::new();
        for word in query
            .split_whitespace()
            .filter(|word| has_token_character(word))
        {
            let word = word.to_lowercase();
            if !terms.contains(&word) {
                terms.push(word);
            }
        }
        ensure!(terms.len() <= 8, "query accepts at most 8 distinct terms");
        ensure!(!terms.is_empty(), "query must contain a searchable word");
        Ok(terms)
    }
}

fn has_token_character(word: &str) -> bool {
    static TOKEN_CHAR: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"[\p{L}\p{N}\p{Co}]").expect("valid unicode61 token categories")
    });
    TOKEN_CHAR.is_match(word)
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

fn literal(term: &str, prefix: bool) -> String {
    format!(
        "\"{}\"{}",
        term.replace('"', "\"\""),
        if prefix { "*" } else { "" }
    )
}

pub(crate) fn search(
    db: &Reader,
    request: &Request,
    control: &Arc<ReadControl>,
    completed: &Completed,
) -> Result<Response> {
    let terms = request.terms()?;
    let expressions: Vec<_> = terms
        .iter()
        .enumerate()
        .map(|(n, t)| literal(t, n + 1 == terms.len()))
        .collect();
    let expression = expressions.join(" AND ");
    let run = || -> Result<Response> {
        ensure!(!control.stopped(), "conversation search interrupted");
        let snapshot = db.unchecked_transaction()?;
        let db = &snapshot;
        if !super::index::ready(db)? {
            return Ok(Response {
                schema_version: 1,
                truncated: true,
                conversations: Vec::new(),
            });
        }
        let incomplete: bool = db.query_row("SELECT (SELECT value FROM meta WHERE key='catalog_ready')<>'1' OR EXISTS(SELECT 1 FROM meta WHERE key='mirror_rebuilding') OR EXISTS(SELECT 1 FROM search_dirty WHERE backfill=1) OR EXISTS(SELECT 1 FROM coverage WHERE stale_reason IS NOT NULL OR complete_through IS NULL)", [], |r| r.get(0))?;
        let mut statement = db.prepare("SELECT s.session_key,s.origin_host,s.provider,s.thread_id,s.cwd,s.title,s.started_at,s.last_at,s.parent_session_key,src.present FROM conversation_fts JOIN search_document d ON d.id=conversation_fts.rowid JOIN session s ON s.session_key=d.session_key JOIN source src USING(source_id) WHERE conversation_fts MATCH ?1 AND src.present=1 ORDER BY bm25(conversation_fts,8,4,1,0),s.last_at DESC,s.session_key LIMIT 129")?;
        let candidates: Vec<_> = statement
            .query_map([&expression], super::query::session_header)?
            .collect::<rusqlite::Result<_>>()?;
        let mut response = Response {
            schema_version: 1,
            truncated: incomplete || candidates.len() > 128,
            conversations: Vec::new(),
        };
        *completed
            .lock()
            .expect("conversation search progress poisoned") = Some(response.clone());
        let snippets = Snippets::new(control, &expressions)?;
        let mut find_hits = db.prepare("SELECT i.rowid,i.kind,i.at,i.text_bytes FROM item_word_fts JOIN item i ON i.rowid=item_word_fts.rowid WHERE item_word_fts MATCH ?1 ORDER BY item_word_fts.rowid DESC LIMIT ?2")?;
        let mut hit_text = db.prepare("SELECT i.item_key,s.thread_id,i.session_key,i.text FROM item i JOIN session s USING(session_key) WHERE i.rowid=?1")?;
        for header in candidates.into_iter().take(128) {
            ensure!(!control.stopped(), "conversation search interrupted");
            let title_match: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_fts JOIN search_document d ON d.id=conversation_fts.rowid WHERE d.session_key=?1 AND conversation_fts MATCH ?2)", params![header.session_key, format!("title:({expression})")], |r| r.get(0))?;
            let (scopes, capped) = super::index::member_scopes(db, &header.session_key)?;
            response.truncated |= capped;
            let scope = scopes
                .iter()
                .map(|s| format!("scope:{s}"))
                .collect::<Vec<_>>()
                .join(" OR ");
            let mut hits = HashMap::new();
            if !scope.is_empty() {
                for (n, term) in expressions.iter().enumerate() {
                    let stage: Vec<(i64, String, Option<String>, i64)> = find_hits
                        .query_map(
                            params![format!("({scope}) AND text:{term}"), TERM_WINDOW as i64 + 1],
                            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                        )?
                        .collect::<rusqlite::Result<_>>()?;
                    response.truncated |= stage.len() > TERM_WINDOW;
                    for (id, kind, at, bytes) in stage.into_iter().take(TERM_WINDOW) {
                        hits.entry(id)
                            .and_modify(|hit: &mut RankedHit| hit.terms |= 1 << n)
                            .or_insert(RankedHit {
                                terms: 1 << n,
                                kind,
                                at,
                                bytes,
                            });
                    }
                }
            }
            let hit_count = hits.len();
            if !title_match && hit_count == 0 {
                continue;
            }
            let mut hits: Vec<_> = hits.into_iter().collect();
            hits.sort_by(|(a, left), (b, right)| {
                right
                    .terms
                    .count_ones()
                    .cmp(&left.terms.count_ones())
                    .then_with(|| right.at.cmp(&left.at))
                    .then_with(|| b.cmp(a))
            });
            let mut excerpts = Vec::new();
            for (id, hit) in hits {
                ensure!(!control.stopped(), "conversation search interrupted");
                if hit.bytes > EXCERPT_INPUT_BYTES {
                    response.truncated = true;
                    continue;
                }
                let (item_key, thread_id, session_key, text): (String, String, String, String) =
                    hit_text
                        .query_row([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
                excerpts.push(Hit {
                    item_key,
                    kind: hit.kind,
                    at: hit.at,
                    agent_thread_id: (session_key != header.session_key).then_some(thread_id),
                    excerpt: snippets.render(&text)?,
                });
                if excerpts.len() == 3 {
                    break;
                }
            }
            response.conversations.push(Conversation {
                session_key: header.session_key,
                host_id: header.host_id,
                provider: header.provider,
                thread_id: header.thread_id,
                title: header.title,
                cwd: header.cwd,
                last_at: header.last_at,
                title_match,
                hit_count,
                hits: excerpts,
            });
            *completed
                .lock()
                .expect("conversation search progress poisoned") = Some(response.clone());
            if response.conversations.len() == request.limit {
                break;
            }
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

struct RankedHit {
    terms: u8,
    kind: String,
    at: Option<String>,
    bytes: i64,
}

struct Snippets {
    db: Connection,
    expression: String,
}

impl Snippets {
    fn new(control: &Arc<ReadControl>, expressions: &[String]) -> Result<Self> {
        let mut db = Connection::open_in_memory()?;
        control.install(&mut db)?;
        db.execute_batch("CREATE VIRTUAL TABLE excerpt_fts USING fts5(text,tokenize='unicode61 remove_diacritics 2')")?;
        Ok(Self {
            db,
            expression: expressions.join(" OR "),
        })
    }

    fn render(&self, text: &str) -> Result<String> {
        self.db.execute(
            "INSERT OR REPLACE INTO excerpt_fts(rowid,text) VALUES(1,?1)",
            [text],
        )?;
        let snippet: String = self.db.query_row(
            "SELECT snippet(excerpt_fts,0,'\u{e000}','\u{e001}','…',32) FROM excerpt_fts WHERE excerpt_fts MATCH ?1",
            [&self.expression], |r| r.get(0),
        )?;
        Ok(excerpt(&snippet))
    }
}

fn excerpt(snippet: &str) -> String {
    let mut text = Vec::new();
    let mut anchor = None;
    for ch in snippet.chars() {
        match ch {
            '\u{e000}' => {
                anchor.get_or_insert(text.len());
            }
            '\u{e001}' => {}
            ch => text.push(ch),
        }
    }
    if text.len() <= 240 {
        return text.into_iter().collect();
    }
    let start = anchor
        .unwrap_or_default()
        .saturating_sub(119)
        .min(text.len() - 238);
    let end = (start + 238).min(text.len());
    let mut result = String::new();
    if start > 0 {
        result.push('…');
    }
    result.extend(text[start..end].iter());
    if end < text.len() {
        result.push('…');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_conversation_term_categories_match_unicode61() -> Result<()> {
        let db = rusqlite::Connection::open_in_memory()?;
        db.execute_batch("CREATE VIRTUAL TABLE token_probe USING fts5(text,tokenize='unicode61 remove_diacritics 2')")?;
        for (term, searchable) in [
            ("a", true),
            ("Malmö", true),
            ("漢", true),
            ("9", true),
            ("Ⅳ", true),
            ("\u{e016}", true),
            ("->", false),
            ("—", false),
            ("&", false),
            ("€", false),
            ("😀", false),
            ("\u{0345}", false),
            ("\"", false),
        ] {
            db.execute("DELETE FROM token_probe", [])?;
            db.execute("INSERT INTO token_probe VALUES(?1)", [term])?;
            let matches: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM token_probe WHERE token_probe MATCH ?1)",
                [literal(term, false)],
                |r| r.get(0),
            )?;
            assert_eq!(matches, searchable, "{term:?}");
            assert_eq!(has_token_character(term), matches, "{term:?}");
        }
        assert!(!has_token_character("🧰"));
        assert_eq!(
            Request {
                query: "a -> b & c — d $ e -> f -> g -> h".into(),
                limit: 1
            }
            .terms()?
            .len(),
            8
        );
        Ok(())
    }
}
