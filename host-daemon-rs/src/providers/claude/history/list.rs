use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::providers::claude::projection::HistoryError;

const CURSOR_PREFIX: &str = "claude-list-1:";
const CURSOR_LIMIT: usize = 2_048;
const SEARCH_LIMIT: usize = 4_096;

pub(crate) struct ThreadListQuery {
    limit: usize,
    terms: Vec<String>,
    digest: String,
    anchor: Option<Cursor>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    thread_id: String,
    updated_at: i64,
    query_digest: String,
}

impl ThreadListQuery {
    pub(crate) fn new(
        limit: u64,
        cursor: Option<&str>,
        search: Option<&str>,
    ) -> Result<Self, HistoryError> {
        let search = search.unwrap_or_default();
        if search.len() > SEARCH_LIMIT {
            return Err(HistoryError::InvalidRequest(
                "searchTerm exceeds 4096 bytes".into(),
            ));
        }
        let terms: Vec<String> = search.split_whitespace().map(str::to_lowercase).collect();
        let digest = blake3::hash(terms.join(" ").as_bytes())
            .to_hex()
            .to_string();
        let anchor = cursor
            .map(|cursor| {
                if cursor.len() > CURSOR_LIMIT {
                    return Err(invalid_cursor());
                }
                let raw = cursor
                    .strip_prefix(CURSOR_PREFIX)
                    .ok_or_else(invalid_cursor)?;
                let decoded = URL_SAFE_NO_PAD.decode(raw).map_err(|_| invalid_cursor())?;
                let anchor: Cursor =
                    serde_json::from_slice(&decoded).map_err(|_| invalid_cursor())?;
                if anchor.query_digest != digest
                    || !anchor.thread_id.starts_with("claude_")
                    || anchor.thread_id.len() <= "claude_".len()
                    || anchor.thread_id.len() > 512
                {
                    return Err(invalid_cursor());
                }
                Ok(anchor)
            })
            .transpose()?;
        Ok(Self {
            limit: limit.clamp(1, 500) as usize,
            terms,
            digest,
            anchor,
        })
    }

    pub(super) fn page<'a>(
        &self,
        headers: impl IntoIterator<Item = &'a Value>,
    ) -> Result<Value, HistoryError> {
        let mut data = Vec::new();
        let mut has_more = false;
        for header in headers {
            let id = header["id"]
                .as_str()
                .ok_or_else(|| invalid_header("missing identity"))?;
            let updated_at = header["updatedAt"]
                .as_i64()
                .ok_or_else(|| invalid_header("missing activity time"))?;
            if self.anchor.as_ref().is_some_and(|anchor| {
                updated_at > anchor.updated_at
                    || (updated_at == anchor.updated_at && id <= anchor.thread_id.as_str())
            }) || !self.matches(header)
            {
                continue;
            }
            if data.len() == self.limit {
                has_more = true;
                break;
            }
            data.push(header.clone());
        }
        let next_cursor = if has_more {
            let last = data.last().ok_or_else(|| invalid_header("empty page"))?;
            let cursor = Cursor {
                thread_id: last["id"]
                    .as_str()
                    .ok_or_else(|| invalid_header("missing identity"))?
                    .into(),
                updated_at: last["updatedAt"]
                    .as_i64()
                    .ok_or_else(|| invalid_header("missing activity time"))?,
                query_digest: self.digest.clone(),
            };
            let raw = serde_json::to_vec(&cursor).map_err(anyhow::Error::from)?;
            Some(format!("{CURSOR_PREFIX}{}", URL_SAFE_NO_PAD.encode(raw)))
        } else {
            None
        };
        Ok(json!({"data":data,"nextCursor":next_cursor}))
    }

    fn matches(&self, header: &Value) -> bool {
        if self.terms.is_empty() {
            return true;
        }
        let title = header["name"]
            .as_str()
            .filter(|name| !name.trim().is_empty())
            .or_else(|| header["preview"].as_str())
            .unwrap_or_default()
            .to_lowercase();
        let cwd = header["cwd"].as_str().unwrap_or_default().to_lowercase();
        self.terms
            .iter()
            .all(|term| title.contains(term) || cwd.contains(term))
    }
}

fn invalid_cursor() -> HistoryError {
    HistoryError::InvalidCursor("Claude list cursor is malformed or belongs to a different search; read the first page again".into())
}

fn invalid_header(reason: &str) -> HistoryError {
    HistoryError::Internal(anyhow::anyhow!("Invalid Claude list header: {reason}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_list_cursors_reject_wrong_scope_version_shape_and_query() {
        let valid = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&Cursor {
                thread_id: "claude_a".into(),
                updated_at: 1,
                query_digest: "wrong".into(),
            })
            .unwrap(),
        );
        let wrong_shape =
            URL_SAFE_NO_PAD.encode(br#"{"threadId":1,"updatedAt":1,"queryDigest":"wrong"}"#);
        for cursor in [
            String::new(),
            "other-list-1:opaque".into(),
            "claude-list-2:opaque".into(),
            "claude-list-1:%%%".into(),
            "x".repeat(CURSOR_LIMIT + 1),
            format!("{CURSOR_PREFIX}{valid}"),
            format!("{CURSOR_PREFIX}{wrong_shape}"),
        ] {
            assert!(matches!(
                ThreadListQuery::new(1, Some(&cursor), None),
                Err(HistoryError::InvalidCursor(_))
            ));
        }
        assert!(matches!(
            ThreadListQuery::new(1, None, Some(&"x".repeat(SEARCH_LIMIT + 1))),
            Err(HistoryError::InvalidRequest(_))
        ));
    }

    #[test]
    fn claude_list_search_uses_effective_titles_and_directories_before_paging() {
        let headers = vec![
            json!({"id":"claude_a","updatedAt":3,"name":"Visible title", "preview":"hidden keyword", "cwd":"/other"}),
            json!({"id":"claude_b","updatedAt":2,"name":null,"preview":"Ångström guide", "cwd":"/repo"}),
            json!({"id":"claude_c","updatedAt":1,"name":"Ångström notes", "preview":"other", "cwd":"/repo"}),
        ];
        let first = ThreadListQuery::new(1, None, Some(" ÅNGSTRÖM   repo "))
            .unwrap()
            .page(&headers)
            .unwrap();
        assert_eq!(first["data"][0]["id"], "claude_b");
        let cursor = first["nextCursor"].as_str().unwrap();
        let second = ThreadListQuery::new(1, Some(cursor), Some("ångström repo"))
            .unwrap()
            .page(&headers)
            .unwrap();
        assert_eq!(second["data"][0]["id"], "claude_c");
        assert!(second["nextCursor"].is_null());
        let absent = ThreadListQuery::new(10, None, Some("hidden"))
            .unwrap()
            .page(&headers)
            .unwrap();
        assert_eq!(absent["data"], json!([]));
        assert!(absent["nextCursor"].is_null());
    }
}
