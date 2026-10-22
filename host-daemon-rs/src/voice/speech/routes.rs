use axum::http::{HeaderName, Method};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Provider {
    OpenAi,
    ElevenLabs,
    Gemini,
    AssemblyAi,
    Azure,
}

impl Provider {
    pub(crate) const ALL: [Provider; 5] = [
        Provider::OpenAi,
        Provider::ElevenLabs,
        Provider::Gemini,
        Provider::AssemblyAi,
        Provider::Azure,
    ];

    pub(crate) fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|provider| provider.name() == name)
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Provider::OpenAi => "openai",
            Provider::ElevenLabs => "elevenlabs",
            Provider::Gemini => "gemini",
            Provider::AssemblyAi => "assemblyai",
            Provider::Azure => "azure",
        }
    }

    pub(crate) fn credential_header(self, api_key: &str) -> (HeaderName, String) {
        match self {
            Provider::OpenAi => (
                HeaderName::from_static("authorization"),
                format!("Bearer {api_key}"),
            ),
            Provider::ElevenLabs => (HeaderName::from_static("xi-api-key"), api_key.to_owned()),
            Provider::Gemini => (
                HeaderName::from_static("x-goog-api-key"),
                api_key.to_owned(),
            ),
            Provider::AssemblyAi => (HeaderName::from_static("authorization"), api_key.to_owned()),
            Provider::Azure => (
                HeaderName::from_static("ocp-apim-subscription-key"),
                api_key.to_owned(),
            ),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Transport {
    Http,
    WebSocket,
}

impl Transport {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Transport::Http => "http",
            Transport::WebSocket => "webSocket",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Origin {
    OpenAi,
    ElevenLabs,
    Gemini,
    AssemblyAiApi,
    AssemblyAiStreaming,
    AzureResource,
}

impl Origin {
    pub(crate) fn router_vendor(self) -> &'static str {
        match self {
            Origin::OpenAi => "openai",
            Origin::ElevenLabs => "elevenlabs",
            Origin::Gemini => "google",
            Origin::AssemblyAiApi => "assemblyai",
            Origin::AssemblyAiStreaming => "assemblyai-streaming",
            Origin::AzureResource => "azure-speech",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Operation {
    pub name: &'static str,
    pub transport: Transport,
    pub origin: Origin,
}

#[derive(Clone, Copy)]
enum Verb {
    Get,
    Post,
    Delete,
}

impl Verb {
    fn matches(self, method: &Method) -> bool {
        match self {
            Verb::Get => method == Method::GET,
            Verb::Post => method == Method::POST,
            Verb::Delete => method == Method::DELETE,
        }
    }
}

#[derive(Clone, Copy)]
enum Segment {
    Exact(&'static str),
    Identifier,
    IdentifierWithSuffix(&'static str),
}

impl Segment {
    fn matches(self, segment: &str) -> bool {
        match self {
            Segment::Exact(expected) => segment == expected,
            Segment::Identifier => !segment.contains(':'),
            Segment::IdentifierWithSuffix(suffix) => segment
                .strip_suffix(suffix)
                .is_some_and(|stem| !stem.is_empty() && !stem.contains(':')),
        }
    }
}

struct Route {
    provider: Provider,
    verb: Verb,
    segments: &'static [Segment],
    operation: Operation,
}

const fn route(
    provider: Provider,
    verb: Verb,
    segments: &'static [Segment],
    name: &'static str,
    transport: Transport,
    origin: Origin,
) -> Route {
    Route {
        provider,
        verb,
        segments,
        operation: Operation {
            name,
            transport,
            origin,
        },
    }
}

use Segment::{Exact, Identifier, IdentifierWithSuffix};

const ROUTES: &[Route] = &[
    route(
        Provider::OpenAi,
        Verb::Get,
        &[Exact("v1"), Exact("realtime")],
        "realtime",
        Transport::WebSocket,
        Origin::OpenAi,
    ),
    route(
        Provider::OpenAi,
        Verb::Post,
        &[Exact("v1"), Exact("audio"), Exact("transcriptions")],
        "transcription",
        Transport::Http,
        Origin::OpenAi,
    ),
    route(
        Provider::ElevenLabs,
        Verb::Get,
        &[Exact("v1"), Exact("speech-to-text"), Exact("realtime")],
        "realtime",
        Transport::WebSocket,
        Origin::ElevenLabs,
    ),
    route(
        Provider::ElevenLabs,
        Verb::Post,
        &[Exact("v1"), Exact("speech-to-text")],
        "transcription",
        Transport::Http,
        Origin::ElevenLabs,
    ),
    route(
        Provider::Gemini,
        Verb::Get,
        &[
            Exact("ws"),
            Exact("google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"),
        ],
        "realtime",
        Transport::WebSocket,
        Origin::Gemini,
    ),
    route(
        Provider::Gemini,
        Verb::Post,
        &[
            Exact("v1beta"),
            Exact("models"),
            IdentifierWithSuffix(":generateContent"),
        ],
        "generateContent",
        Transport::Http,
        Origin::Gemini,
    ),
    route(
        Provider::Gemini,
        Verb::Post,
        &[
            Exact("v1beta"),
            Exact("models"),
            IdentifierWithSuffix(":streamGenerateContent"),
        ],
        "streamGenerateContent",
        Transport::Http,
        Origin::Gemini,
    ),
    route(
        Provider::Gemini,
        Verb::Post,
        &[Exact("upload"), Exact("v1beta"), Exact("files")],
        "fileUpload",
        Transport::Http,
        Origin::Gemini,
    ),
    route(
        Provider::Gemini,
        Verb::Post,
        &[Exact("v1beta"), Exact("interactions")],
        "interaction",
        Transport::Http,
        Origin::Gemini,
    ),
    route(
        Provider::Gemini,
        Verb::Delete,
        &[Exact("v1beta"), Exact("files"), Identifier],
        "fileDelete",
        Transport::Http,
        Origin::Gemini,
    ),
    route(
        Provider::AssemblyAi,
        Verb::Get,
        &[Exact("v3"), Exact("ws")],
        "realtime",
        Transport::WebSocket,
        Origin::AssemblyAiStreaming,
    ),
    route(
        Provider::AssemblyAi,
        Verb::Post,
        &[Exact("v2"), Exact("upload")],
        "upload",
        Transport::Http,
        Origin::AssemblyAiApi,
    ),
    route(
        Provider::AssemblyAi,
        Verb::Post,
        &[Exact("v2"), Exact("transcript")],
        "transcript",
        Transport::Http,
        Origin::AssemblyAiApi,
    ),
    route(
        Provider::AssemblyAi,
        Verb::Get,
        &[Exact("v2"), Exact("transcript"), Identifier],
        "transcriptStatus",
        Transport::Http,
        Origin::AssemblyAiApi,
    ),
    route(
        Provider::Azure,
        Verb::Post,
        &[Exact("speechtotext"), Exact("transcriptions:transcribe")],
        "transcription",
        Transport::Http,
        Origin::AzureResource,
    ),
];

pub(crate) fn operation(
    provider: Provider,
    method: &Method,
    path: &str,
    transport: Transport,
) -> Option<Operation> {
    let segments: Vec<&str> = path.strip_prefix('/')?.split('/').collect();
    if !segments.iter().all(|segment| valid_segment(segment)) {
        return None;
    }
    ROUTES
        .iter()
        .find(|route| {
            route.provider == provider
                && route.operation.transport == transport
                && route.verb.matches(method)
                && route.segments.len() == segments.len()
                && route
                    .segments
                    .iter()
                    .zip(&segments)
                    .all(|(pattern, segment)| pattern.matches(segment))
        })
        .map(|route| route.operation)
}

fn valid_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && segment
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speechkit_operations_are_allowlisted_by_provider_method_path_and_transport() {
        macro_rules! check {
            ($provider:ident, $method:ident, $transport:ident, $path:literal, $expected:expr) => {
                assert_eq!(
                    operation(
                        Provider::$provider,
                        &Method::$method,
                        $path,
                        Transport::$transport
                    )
                    .map(|operation| operation.name),
                    $expected,
                    "{} {} {} {}",
                    stringify!($provider),
                    stringify!($method),
                    $path,
                    stringify!($transport)
                );
            };
        }
        check!(
            Gemini,
            POST,
            Http,
            "/v1beta/models/gemini-3.5-flash:generateContent",
            Some("generateContent")
        );
        check!(
            Gemini,
            POST,
            Http,
            "/v1beta/models/gemini-3.1-flash-tts-preview:streamGenerateContent",
            Some("streamGenerateContent")
        );
        check!(
            Gemini,
            DELETE,
            Http,
            "/v1beta/files/abc-123",
            Some("fileDelete")
        );
        check!(
            AssemblyAi,
            GET,
            Http,
            "/v2/transcript/5f2a",
            Some("transcriptStatus")
        );
        check!(
            Azure,
            POST,
            Http,
            "/speechtotext/transcriptions:transcribe",
            Some("transcription")
        );
        check!(
            ElevenLabs,
            POST,
            Http,
            "/v1/speech-to-text",
            Some("transcription")
        );
        check!(OpenAi, GET, WebSocket, "/v1/realtime", Some("realtime"));
        check!(OpenAi, GET, Http, "/v1/audio/transcriptions", None);
        check!(OpenAi, POST, Http, "/v1/chat/completions", None);
        check!(OpenAi, GET, Http, "/v1/realtime", None);
        check!(OpenAi, POST, WebSocket, "/v1/audio/transcriptions", None);
        check!(Gemini, DELETE, Http, "/v1beta/files/../models", None);
        check!(Gemini, DELETE, Http, "/v1beta/files/a%2Fb", None);
        check!(Gemini, POST, Http, "/v1beta/models/:generateContent", None);
        check!(
            Gemini,
            POST,
            Http,
            "/v1beta/models/a:b:generateContent",
            None
        );
        check!(Gemini, POST, Http, "/v1beta/interactions/", None);
        check!(Azure, POST, Http, "/v1/speech-to-text", None);
        assert_eq!(
            operation(
                Provider::OpenAi,
                &Method::GET,
                "/v1/realtime",
                Transport::WebSocket
            )
            .map(|operation| operation.origin),
            Some(Origin::OpenAi)
        );
    }
}
