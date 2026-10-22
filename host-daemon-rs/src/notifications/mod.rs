pub(crate) mod history;

use serde_json::Value;

pub(crate) fn should_store_notification_method(method: &str) -> bool {
    !is_realtime_item_stream_notification(method)
        && !is_streaming_delta(method)
        && (method.starts_with("thread/")
            || method.starts_with("turn/")
            || method.starts_with("item/")
            || method.starts_with("account/")
            || method == "error")
}

fn is_streaming_delta(method: &str) -> bool {
    method.ends_with("/delta") || method.ends_with("Delta")
}

pub(crate) fn is_realtime_item_stream_notification(method: &str) -> bool {
    matches!(
        method,
        "thread/realtime/item/started"
            | "thread/realtime/item/transcript/delta"
            | "thread/realtime/item/completed"
    )
}

pub(crate) fn realtime_notification_method(message: &Value) -> Option<&str> {
    message
        .get("method")
        .and_then(Value::as_str)
        .filter(|method| method.starts_with("thread/realtime/"))
}

pub(crate) fn notification_thread_id(message: &Value) -> Option<String> {
    let params = message.get("params")?;
    params
        .get("threadId")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("thread")
                .and_then(|thread| thread.get("id"))
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_string)
}
