use serde_json::{Value, json};

/// The namespace both projections expose these tools under.
pub(crate) const NAMESPACE: &str = "remotecoder";

pub(crate) const END_VOICE_CALL: &str = "end_voice_call";
pub(crate) const NOTIFY_USER: &str = "notify_user";
pub(crate) const REQUEST_CALL: &str = "request_call";
pub(crate) const CALL_STATUS: &str = "call_status";
pub(crate) const END_CALL: &str = "end_call";
pub(crate) const TAKE_PHOTO: &str = "take_photo";
pub(crate) const PUBLISH_VISUAL: &str = "publish_visual";
pub(crate) const STEER_CALL: &str = "steer_call";

/// One tool as both projections need to describe it.
pub(crate) struct ToolDefinition {
    pub name: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    /// JSON Schema for the arguments object.
    pub input_schema: fn() -> Value,
}

fn end_voice_call_schema() -> Value {
    json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    })
}

fn request_call_schema() -> Value {
    json!({"type":"object", "properties": {
        "requestId": {"type":"string", "description":"Stable idempotency key. Reuse it when retrying this exact request."},
        "to": {"type":"string", "description":"self rings the user in RemoteCoder; an authorized E.164 number requests telephone delivery."},
        "brief": {"type":"object", "properties": {
            "purpose":{"type":"string"}, "language":{"type":"string"}, "context":{"type":"string"},
            "scope":{"type":"string", "description":"Permitted actions and disclosures; telephone recipients cannot broaden this."},
            "stopConditions":{"type":"string"}, "opening":{"type":["string","null"]}
        }, "required":["purpose","language","context","scope","stopConditions","opening"], "additionalProperties":false}
    }, "required":["requestId","to","brief"], "additionalProperties":false})
}

fn call_id_schema() -> Value {
    json!({"type":"object", "properties":{"callId":{"type":"string", "description":"Exact ID returned by request_call; never substitute another call."}},
        "required":["callId"], "additionalProperties":false})
}

fn steer_call_schema() -> Value {
    json!({"type":"object", "properties":{
        "callId":{"type":"string"}, "message":{"type":"string", "description":"Concise guidance, a question or verified information for GPT Live; up to 2,000 UTF-8 bytes."}
    }, "required":["callId","message"], "additionalProperties":false})
}

fn notify_user_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "Short notification title, a few words."
            },
            "body": {
                "type": "string",
                "description": "The message body. One or two sentences."
            },
        },
        "required": ["title", "body"],
        "additionalProperties": false
    })
}

fn take_photo_schema() -> Value {
    json!({"type":"object", "properties": {
        "camera":{"type":"string", "enum":["back","front","both"], "default":"back"},
        "lens":{"type":"string", "enum":["wide","ultra_wide","telephoto"], "default":"wide", "description":"Selects the back lens. Front always uses wide; both captures back with this lens, then front wide."}
    }, "additionalProperties":false})
}

fn publish_visual_schema() -> Value {
    json!({"type":"object", "properties": {
        "html":{"type":"string", "description":"The complete HTML document or fragment. Give either html or path."},
        "path":{"type":"string", "description":"Absolute path to an HTML file you generated, for example with a script; relative local image paths resolve against its directory."},
        "title":{"type":"string", "description":"Short descriptive title, 1–200 UTF-8 bytes without control characters."}
    }, "required":["title"], "additionalProperties":false})
}

pub(crate) fn definitions() -> &'static [ToolDefinition] {
    &[
        ToolDefinition {
            name: PUBLISH_VISUAL,
            title: "Publish an inline HTML visual",
            description: "Show HTML inline in this conversation. It appears automatically; your answer needs no embed. Strongly prefer it to Markdown: present any answer beyond very basic text as HTML, such as steps, comparisons, status, plans or numbers, mixing styled text, layout, charts, interaction or anything a browser can render. Draw every diagram, sequence and flow in a visual, never as Mermaid. Keep Markdown only for a few plain sentences or a short list and for commands or code to copy. Open with a short plain-text lead for voice and other clients; let the HTML carry the rest without repeating it. Pass HTML inline as html with a short title; use path only for a file you generated. Publishing returns a light | dark render and errors, so skip your own screenshots. Republish with the same title to replace a visual in this turn; a new title adds one. Show local images by absolute path in <img src>; publishing converts and downscales them, HEIC included. A visual holds up to 2 MiB after embedding; anything else may load over https, but history reopens offline, so keep visuals meaningful without it. Taps on media open a viewer unless prevented. Inline height follows the content: avoid vh and height:100%, reserve network media sizes and fit ~360pt iPhone and wider Mac widths. Inline shows ~6,000pt before Expand. JS and CSS animation runs freely on live pages; a still snapshot stands in while scrolling or off-screen, so keep height stable during motion, make paused frames read well and respect prefers-reduced-motion. Snapshots drop gradient-stop alpha, so keep stops opaque. Size text in em or var(--rc-font-size) to follow the app's text size; SVG labels may scale with their chart. The app's live theme is --rc-text, --rc-secondary-text, --rc-background, --rc-surface, --rc-accent, --rc-font-family and color-scheme:var(--rc-color-scheme); build text, surfaces and controls on them so light/dark and contrast follow the app, never on hardcoded colors, a fixed root theme or prefers-color-scheme. Distinct chart series colors are fine.",
            input_schema: publish_visual_schema,
        },
        ToolDefinition {
            name: TAKE_PHOTO,
            title: "Take an iPhone photo",
            description: "Take a photo with the user's iPhone and return the image. Works only when this turn came from the RemoteCoder iPhone app and the app is open on screen; otherwise explains why it could not run. camera=both captures back, then front. The host saves each full-size original and returns its path when saving succeeds.",
            input_schema: take_photo_schema,
        },
        ToolDefinition {
            name: REQUEST_CALL,
            title: "Request a call",
            description: "Request an authorized outgoing voice call, bound to this exact agent conversation. Use self to ring the user in RemoteCoder by default. Supply the immutable call brief and a stable requestId. Returns a durable call ID promptly, not proof of ringing or task completion. The call survives this tool and your turn ending; spoken handoffs return to this conversation. Check call_status and use end_call with this ID. Never use this to contact someone without the task's required authority.",
            input_schema: request_call_schema,
        },
        ToolDefinition {
            name: CALL_STATUS,
            title: "Read call status",
            description: "Read the durable state of a call owned by this conversation. Connection state is separate from the underlying task outcome.",
            input_schema: call_id_schema,
        },
        ToolDefinition {
            name: END_CALL,
            title: "End an agent-initiated call",
            description: "End the exact agent-initiated call returned by request_call. Does not cancel the underlying conversation or agent work. Closing speech must be delivered before ending media.",
            input_schema: call_id_schema,
        },
        ToolDefinition {
            name: END_VOICE_CALL,
            title: "End user-started voice call",
            description: "End the current user-started RemoteCoder Voice Mode call owned by this conversation. For an agent-initiated call, use end_call with its exact callId. The underlying agent task continues.",
            input_schema: end_voice_call_schema,
        },
        ToolDefinition {
            name: STEER_CALL,
            title: "Send guidance to the live call",
            description: "Send guidance, a question or verified information to GPT Live in this exact connected call. GPT Live can use it naturally while continuing the conversation and can delegate back to you. Acceptance means the voice session received the message, not that the recipient heard it. Normal voice handoff replies already flow automatically; use this for additional steering.",
            input_schema: steer_call_schema,
        },
        ToolDefinition {
            name: NOTIFY_USER,
            title: "Notify user",
            description: "\
Send a push notification to the user's iPhone. Use it to reach them about something \
they asked to be told about, or that needs a decision, when they are not already \
watching this conversation. The notification is delivered even if RemoteCoder \
is closed. Do not use it to acknowledge routine progress in a conversation they \
are actively following.",
            input_schema: notify_user_schema,
        },
    ]
}

fn definition(name: &str) -> Option<&'static ToolDefinition> {
    definitions().iter().find(|tool| tool.name == name)
}

/// True when this tool belongs to RemoteCoder's registry.
pub(crate) fn is_registry_tool(namespace: Option<&str>, tool: &str) -> bool {
    // A missing namespace is a foreign call: the gateway declares its tools
    // under NAMESPACE, so claiming a bare name would swallow a client's own
    // dynamic tool that happens to share it.
    namespace == Some(NAMESPACE) && definition(tool).is_some()
}
