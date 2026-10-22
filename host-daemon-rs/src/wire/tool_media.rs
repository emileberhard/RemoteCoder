use super::json::{EncodedJson, encode};
use crate::agents::tools::{NAMESPACE, PUBLISH_VISUAL};
use crate::storage::tool_media::{MediaBatch, ToolMediaStore, media_type_for_path};
use serde_json::{Map, Value, json};
use tracing::warn;

#[derive(Debug)]
pub(crate) enum CompactionError {
    Capacity { bytes: usize },
    Encoding(anyhow::Error),
}

pub(crate) fn may_carry_tool_media(raw: &str) -> bool {
    ["mcpToolCall", "dynamicToolCall", "imageView"]
        .iter()
        .any(|kind| raw.contains(kind))
}

pub(crate) async fn compact_tool_media(
    value: &mut Value,
    store: Option<&ToolMediaStore>,
) -> Result<bool, CompactionError> {
    let mut kept = Kept {
        store,
        batch: MediaBatch::default(),
    };
    let changed = compact(value, &mut kept)?;
    if let Some(store) = store
        && let Err(error) = store.admit(kept.batch).await
    {
        warn!(error = %format!("{error:#}"), "failed to keep tool media for clients");
    }
    Ok(changed)
}

struct Kept<'a> {
    store: Option<&'a ToolMediaStore>,
    batch: MediaBatch,
}

impl Kept<'_> {
    fn stage(&mut self, data: &str, mime_type: Option<&str>, media: &mut Vec<Value>) {
        let Some(store) = self.store else { return };
        let (mime_type, base64) = match data.strip_prefix("data:") {
            Some(url) => {
                let Some((header, payload)) = url.split_once(',') else {
                    return;
                };
                let Some(mime_type) = header.strip_suffix(";base64") else {
                    return;
                };
                (mime_type, payload)
            }
            None => {
                let Some(mime_type) = mime_type else { return };
                (mime_type, data)
            }
        };
        if let Some(path) = store.stage(&mut self.batch, mime_type, base64) {
            media.push(json!({"path": path, "mimeType": mime_type}));
        }
    }
}

fn compact(value: &mut Value, kept: &mut Kept) -> Result<bool, CompactionError> {
    match value {
        Value::Array(values) => {
            let mut changed = false;
            for value in values {
                changed |= compact(value, kept)?;
            }
            Ok(changed)
        }
        Value::Object(object) => {
            let visual_changed = attach_visual(object);
            let mut model_only = Kept {
                store: None,
                batch: MediaBatch::default(),
            };
            let kept = if is_visual_preview(object) {
                &mut model_only
            } else {
                kept
            };
            match object.get("type").and_then(Value::as_str) {
                Some("mcpToolCall") => {
                    let mut media = Vec::new();
                    let changed = match object.get_mut("result") {
                        Some(result) => compact_mcp_result(result, kept, &mut media)?,
                        None => false,
                    };
                    return Ok(attach_media(object, media) | changed | visual_changed);
                }
                Some("dynamicToolCall") => {
                    let mut media = Vec::new();
                    let mut changed = false;
                    if let Some(Value::Array(items)) = object.get_mut("contentItems") {
                        for item in items {
                            if item["type"] == "inputImage"
                                && let Some(url) = item
                                    .as_object_mut()
                                    .and_then(|item| take_data_url(item, "imageUrl"))
                            {
                                kept.stage(&url, None, &mut media);
                                changed = true;
                            }
                        }
                    }
                    return Ok(attach_media(object, media) | changed | visual_changed);
                }
                Some("imageView") => {
                    let mut media = Vec::new();
                    if let Some(url) = take_data_url(object, "imageUrl") {
                        kept.stage(&url, None, &mut media);
                        attach_media(object, media);
                        return Ok(true);
                    }
                    if let Some(path) = object.get("savedPath").and_then(Value::as_str)
                        && let Some(mime_type) = media_type_for_path(path)
                    {
                        media.push(json!({"path": path, "mimeType": mime_type}));
                    }
                    return Ok(attach_media(object, media));
                }
                Some(_) => return Ok(false),
                None => {}
            }
            if object.contains_key("method") && object.contains_key("id") {
                return Ok(false);
            }
            let mut changed = false;
            for key in [
                "params", "result", "thread", "turn", "turns", "items", "item", "data",
            ] {
                if let Some(value) = object.get_mut(key) {
                    changed |= compact(value, kept)?;
                }
            }
            Ok(changed)
        }
        _ => Ok(false),
    }
}

fn is_visual_preview(object: &Map<String, Value>) -> bool {
    object.get("tool").and_then(Value::as_str) == Some(PUBLISH_VISUAL)
        && ["server", "namespace"]
            .iter()
            .any(|key| object.get(*key).and_then(Value::as_str) == Some(NAMESPACE))
}

fn attach_visual(object: &mut Map<String, Value>) -> bool {
    if !is_visual_preview(object)
        || object.get("status").and_then(Value::as_str) != Some("completed")
    {
        return false;
    }
    let content = match object.get("type").and_then(Value::as_str) {
        Some("mcpToolCall") if object.get("error").is_none_or(Value::is_null) => object
            .get("result")
            .and_then(|result| result.get("content")),
        Some("dynamicToolCall") if object.get("success") == Some(&Value::Bool(true)) => {
            object.get("contentItems")
        }
        _ => return false,
    };
    let Some(title) = object
        .get("arguments")
        .and_then(|arguments| arguments.get("title"))
        .and_then(Value::as_str)
    else {
        return false;
    };
    let Some(digest) = content.and_then(|content| visual_digest(content, title)) else {
        return false;
    };
    let visual = json!({"digest": digest, "title": title});
    if object.get("rcVisual") == Some(&visual) {
        return false;
    }
    object.insert("rcVisual".into(), visual);
    true
}

fn visual_digest(content: &Value, title: &str) -> Option<String> {
    for entry in content.as_array()? {
        let Some(text) = entry.get("text").and_then(Value::as_str) else {
            continue;
        };
        for line in text.lines() {
            let Some((_, suffix)) = line.rsplit_once("](rc-visual:") else {
                continue;
            };
            let Some(digest) = suffix.strip_suffix(')') else {
                continue;
            };
            if digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                && line == crate::storage::visuals::embed(title, digest)
            {
                return Some(digest.to_owned());
            }
        }
        if text.trim_start().starts_with('{')
            && text.contains("\"content\"")
            && let Ok(inner) = serde_json::from_str::<Value>(text)
            && let Some(digest) = inner
                .get("content")
                .and_then(|content| visual_digest(content, title))
        {
            return Some(digest);
        }
    }
    None
}

fn compact_mcp_result(
    result: &mut Value,
    kept: &mut Kept,
    media: &mut Vec<Value>,
) -> Result<bool, CompactionError> {
    let mut changed = false;
    if let Some(Value::Array(content)) = result.get_mut("content") {
        for entry in content {
            match entry.get("type").and_then(Value::as_str) {
                Some("image") => {
                    let data = match entry.get_mut("data") {
                        Some(Value::String(data)) if !data.is_empty() => std::mem::take(data),
                        _ => continue,
                    };
                    let mime_type = entry.get("mimeType").cloned().unwrap_or(Value::Null);
                    kept.stage(&data, mime_type.as_str(), media);
                    entry["rcImageOmitted"] =
                        json!({"mimeType": mime_type, "omittedBytes": data.len()});
                    changed = true;
                }
                Some("text") => {
                    if let Some(text) = entry.get("text").and_then(Value::as_str)
                        && text.trim_start().starts_with('{')
                        && text.contains("\"content\"")
                        && let Ok(mut inner) = serde_json::from_str::<Value>(text)
                        && inner.get("content").is_some_and(Value::is_array)
                        && compact_mcp_result(&mut inner, kept, media)?
                    {
                        match encode(&inner).map_err(CompactionError::Encoding)? {
                            EncodedJson::Text(text) => entry["text"] = Value::String(text),
                            EncodedJson::Capacity { bytes } => {
                                return Err(CompactionError::Capacity { bytes });
                            }
                        }
                        changed = true;
                    }
                }
                _ => {}
            }
        }
    }
    if let Some(screenshot) = result.pointer_mut("/_meta/codex~1toolSurface/screenshot") {
        changed |= screenshot
            .as_object_mut()
            .and_then(|screenshot| take_data_url(screenshot, "url"))
            .is_some();
    }
    Ok(changed)
}

fn take_data_url(object: &mut Map<String, Value>, key: &str) -> Option<String> {
    let Some(Value::String(url)) = object.get_mut(key) else {
        return None;
    };
    let (header, _) = url.strip_prefix("data:")?.split_once(',')?;
    let mime_type = header
        .split(';')
        .next()
        .filter(|mime| !mime.is_empty())
        .unwrap_or("text/plain")
        .to_owned();
    let url = std::mem::take(url);
    object.insert(
        "rcImageOmitted".to_owned(),
        json!({"mimeType": mime_type, "omittedBytes": url.len()}),
    );
    Some(url)
}

fn attach_media(object: &mut Map<String, Value>, media: Vec<Value>) -> bool {
    if media.is_empty() {
        return false;
    }
    let mut list = match object.remove("rcMedia") {
        Some(Value::Array(list)) => list,
        _ => Vec::new(),
    };
    let before = list.len();
    for entry in media {
        if !list.contains(&entry) {
            list.push(entry);
        }
    }
    let changed = list.len() != before;
    object.insert("rcMedia".to_owned(), Value::Array(list));
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn nested_mcp_json_preserves_text_and_metadata() {
        let inner = json!({
            "content": [
                {"type": "text", "text": "Visible state"},
                {"type": "image", "mimeType": "image/jpeg", "data": "YWJj", "_meta": {"codex/imageDetail": "original"}}
            ],
            "isError": false
        });
        let mut frame = json!({"result": {"thread": {"turns": [{"items": [{
            "type": "mcpToolCall", "result": {"content": [{"type": "text", "text": inner.to_string()}]}
        }]}]}}});
        assert!(compact_tool_media(&mut frame, None).await.unwrap());
        let text = frame
            .pointer("/result/thread/turns/0/items/0/result/content/0/text")
            .unwrap()
            .as_str()
            .unwrap();
        let compacted: Value = serde_json::from_str(text).unwrap();
        assert_eq!(compacted["content"][0], inner["content"][0]);
        assert_eq!(compacted["content"][1]["data"], "");
        assert_eq!(
            compacted["content"][1]["rcImageOmitted"],
            json!({"mimeType": "image/jpeg", "omittedBytes": 4})
        );
        assert_eq!(
            compacted["content"][1]["_meta"],
            inner["content"][1]["_meta"]
        );
        assert_eq!(compacted["isError"], false);
        assert!(!compact_tool_media(&mut frame, None).await.unwrap());
    }

    #[tokio::test]
    async fn rpc_capacity_nested_mcp_40_mib_text_never_materializes_an_oversized_compacted_string()
    {
        let inner = json!({"content":[
            {"type":"text","text":"x".repeat(40 * 1024 * 1024)},
            {"type":"image","mimeType":"image/png","data":"YWJj"}
        ]})
        .to_string();
        let mut item =
            json!({"type":"mcpToolCall","result":{"content":[{"type":"text","text":inner}]}});
        let outcome = compact_tool_media(&mut item, None).await;
        let Err(CompactionError::Capacity { bytes }) = outcome else {
            panic!("nested result must report capacity");
        };
        assert!(bytes > crate::providers::codex::daemon::MAX_WEBSOCKET_BYTES);
        let text = item
            .pointer("/result/content/0/text")
            .unwrap()
            .as_str()
            .unwrap();
        assert!(
            !text.contains("rcImageOmitted"),
            "oversized compacted JSON was materialized before rejection"
        );
    }

    #[tokio::test]
    async fn direct_mcp_image_keeps_required_fields() {
        let mut item = json!({"type": "mcpToolCall", "result": {"content": [
            {"type": "image", "mimeType": "image/png", "data": "YWJj"}
        ]}});
        assert!(compact_tool_media(&mut item, None).await.unwrap());
        assert_eq!(
            item["result"]["content"][0],
            json!({
                "type": "image", "mimeType": "image/png", "data": "",
                "rcImageOmitted": {"mimeType": "image/png", "omittedBytes": 4}
            })
        );
    }

    #[tokio::test]
    async fn tool_surface_screenshot_only_compacts_its_data_url() {
        let mut item = json!({"type": "mcpToolCall", "result": {
            "_meta": {"codex/toolSurface": {"screenshot": {"url": "data:image/jpeg;base64,YWJj", "width": 100}}},
            "structuredContent": {"url": "data:image/jpeg;base64,YWJj"}
        }});
        assert!(compact_tool_media(&mut item, None).await.unwrap());
        assert_eq!(
            item["result"]["_meta"]["codex/toolSurface"]["screenshot"],
            json!({
                "url": "", "width": 100, "rcImageOmitted": {"mimeType": "image/jpeg", "omittedBytes": 27}
            })
        );
        assert_eq!(
            item["result"]["structuredContent"]["url"],
            "data:image/jpeg;base64,YWJj"
        );
    }

    #[tokio::test]
    async fn publication_metadata_follows_successful_canonical_tool_results() {
        let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let embed = "![A\\[b\\]\\\\c](rc-visual:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)";
        let content =
            json!([{"type":"text", "text":format!("{embed}\nPreview unavailable: no helper.")}]);
        let nested = json!([{"type":"text", "text":json!({"content":content}).to_string()}]);
        let mut frame = json!({"result":{"data":[
            {"item":{"type":"mcpToolCall","server":NAMESPACE,"tool":PUBLISH_VISUAL,
                "status":"completed","arguments":{"title":"A[b]\\c"},"result":{"content":content}}},
            {"item":{"type":"mcpToolCall","server":NAMESPACE,"tool":PUBLISH_VISUAL,
                "status":"completed","arguments":{"title":"A[b]\\c"},"result":{"content":nested}}},
            {"item":{"type":"dynamicToolCall","namespace":NAMESPACE,"tool":PUBLISH_VISUAL,
                "status":"completed","success":true,"arguments":{"title":"A[b]\\c"},"contentItems":[
                    {"type":"inputText","text":embed}]}}
        ]}});
        assert!(compact_tool_media(&mut frame, None).await.unwrap());
        for entry in frame["result"]["data"].as_array().unwrap() {
            assert_eq!(
                entry["item"]["rcVisual"],
                json!({"digest":digest,"title":"A[b]\\c"})
            );
        }
        let first = frame.clone();
        assert!(!compact_tool_media(&mut frame, None).await.unwrap());
        assert_eq!(frame, first);
    }

    #[tokio::test]
    async fn publication_metadata_never_promotes_failed_foreign_or_malformed_results() {
        let original = json!({"type":"dynamicToolCall","namespace":NAMESPACE,"tool":PUBLISH_VISUAL,
            "status":"completed","success":true,"arguments":{"title":"Chart"},"contentItems":[
                {"type":"inputText","text":"![Chart](rc-visual:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)"}]});
        for (key, value) in [
            ("namespace", json!("other")),
            ("tool", json!("read")),
            ("status", json!("inProgress")),
            ("status", json!("failed")),
            ("success", json!(false)),
            ("arguments", json!({"title":"Different"})),
            (
                "contentItems",
                json!([{"type":"inputText","text":"![Chart](rc-visual:ABC)"}]),
            ),
        ] {
            let mut item = original.clone();
            item[key] = value;
            compact_tool_media(&mut item, None).await.unwrap();
            assert!(item.get("rcVisual").is_none(), "promoted invalid {key}");
        }
        let mut failed = json!({"type":"mcpToolCall","server":NAMESPACE,"tool":PUBLISH_VISUAL,
            "status":"completed","arguments":{"title":"Chart"},"error":{"message":"failed"},
            "result":{"content":[{"type":"text","text":original["contentItems"][0]["text"]}]}});
        compact_tool_media(&mut failed, None).await.unwrap();
        assert!(failed.get("rcVisual").is_none());
    }

    #[tokio::test]
    async fn dynamic_images_compact_inline_urls_only() {
        let mut frame = json!({"method": "item/completed", "params": {"item": {
            "type": "dynamicToolCall", "contentItems": [
                {"type": "inputImage", "imageUrl": "data:image/png;base64,YWJj"},
                {"type": "inputImage", "imageUrl": "https://example.com/image.png"},
                {"type": "inputImage", "imageUrl": "/tmp/image.png"}
            ]
        }}});
        assert!(compact_tool_media(&mut frame, None).await.unwrap());
        let items = &frame["params"]["item"]["contentItems"];
        assert_eq!(
            items[0],
            json!({
                "type": "inputImage", "imageUrl": "",
                "rcImageOmitted": {"mimeType": "image/png", "omittedBytes": 26}
            })
        );
        assert_eq!(items[1]["imageUrl"], "https://example.com/image.png");
        assert_eq!(items[2]["imageUrl"], "/tmp/image.png");
    }

    #[tokio::test]
    async fn stored_media_annotates_each_tool_item_once() {
        use sha2::{Digest, Sha256};
        let home = tempfile::tempdir().unwrap();
        let store = ToolMediaStore::new(home.path().to_path_buf());
        let media = |bytes: &[u8], extension: &str, mime_type: &str| {
            let name = format!("tool-media/{:x}.{extension}", Sha256::digest(bytes));
            json!({"path": home.path().join(name), "mimeType": mime_type})
        };
        let nested =
            json!({"content": [{"type": "image", "mimeType": "image/jpeg", "data": "ZGVm"}]})
                .to_string();
        let mut frame = json!({"result": {"data": [
            {"type": "mcpToolCall", "result": {"content": [
                {"type": "image", "mimeType": "image/png", "data": "YWJj"},
                {"type": "image", "data": "data:image/png;base64,YWJj"},
                {"type": "image", "mimeType": "image/svg+xml", "data": "PHN2Zz4="},
                {"type": "text", "text": nested}
            ]}},
            {"type": "dynamicToolCall", "rcMedia": [{"path": "/tmp/a.pdf", "mimeType": "application/pdf"}],
             "contentItems": [{"type": "inputImage", "imageUrl": "data:image/gif;base64,Z2hp"}]},
            {"type": "imageView", "id": "view", "path": "/tmp/sheet.png", "imageUrl": "data:image/png;base64,amts"},
            {"type": "imageView", "id": "saved", "path": "/tmp/sheet.png", "savedPath": "/codex/viewed_images/t/a.jpg"}
        ]}});
        assert!(compact_tool_media(&mut frame, Some(&store)).await.unwrap());
        let items = &frame["result"]["data"];
        assert_eq!(
            items[0]["rcMedia"],
            json!([
                media(b"abc", "png", "image/png"),
                media(b"def", "jpg", "image/jpeg")
            ])
        );
        assert_eq!(
            items[1]["rcMedia"],
            json!([
                {"path": "/tmp/a.pdf", "mimeType": "application/pdf"},
                media(b"ghi", "gif", "image/gif")
            ])
        );
        assert_eq!(
            items[2]["rcMedia"],
            json!([media(b"jkl", "png", "image/png")])
        );
        assert_eq!(items[2]["path"], "/tmp/sheet.png");
        assert_eq!(items[2]["imageUrl"], "");
        assert_eq!(
            items[3]["rcMedia"],
            json!([{"path": "/codex/viewed_images/t/a.jpg", "mimeType": "image/jpeg"}])
        );
        for entry in [
            &items[0]["rcMedia"][1],
            &items[1]["rcMedia"][1],
            &items[2]["rcMedia"][0],
        ] {
            assert!(std::path::Path::new(entry["path"].as_str().unwrap()).is_file());
        }
        let compacted = frame.clone();
        assert!(!compact_tool_media(&mut frame, Some(&store)).await.unwrap());
        assert_eq!(frame, compacted);
    }

    #[tokio::test]
    async fn visual_previews_reach_only_the_model() {
        let home = tempfile::tempdir().unwrap();
        let store = ToolMediaStore::new(home.path().to_path_buf());
        let mut frame = json!({"result": {"data": [
            {"type": "mcpToolCall", "server": NAMESPACE, "tool": PUBLISH_VISUAL, "result": {"content": [
                {"type": "image", "mimeType": "image/jpeg", "data": "YWJj"}
            ]}},
            {"type": "dynamicToolCall", "namespace": NAMESPACE, "tool": PUBLISH_VISUAL,
             "contentItems": [{"type": "inputImage", "imageUrl": "data:image/jpeg;base64,YWJj"}]}
        ]}});
        assert!(compact_tool_media(&mut frame, Some(&store)).await.unwrap());
        let items = &frame["result"]["data"];
        assert_eq!(items[0]["result"]["content"][0]["data"], "");
        assert_eq!(items[1]["contentItems"][0]["imageUrl"], "");
        assert!(items[0].get("rcMedia").is_none() && items[1].get("rcMedia").is_none());
        assert!(!home.path().join("tool-media").exists());
    }

    #[tokio::test]
    async fn user_images_and_tool_arguments_are_unchanged() {
        let mut frame = json!({"result": {"data": [
            {"type": "userMessage", "content": [{"type": "inputImage", "imageUrl": "data:image/png;base64,YWJj"}]},
            {"type": "mcpToolCall", "arguments": {"data": "YWJj"}, "result": {"content": [{"type": "text", "text": " { \"content\": [] } "}]}},
            {"type": "mcpToolCall", "result": {"_meta": {"codex/toolSurface": {"screenshot": {"url": "file:///tmp/image.png"}}}}}
        ]}});
        let original = frame.clone();
        assert!(!compact_tool_media(&mut frame, None).await.unwrap());
        assert_eq!(frame, original);
    }
}
