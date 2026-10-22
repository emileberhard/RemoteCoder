import Foundation

enum CodexInteractionMode: Sendable {
    case text
    case voice

    static let additionalContextKey = "remote_coder_interaction_mode"

    var additionalContext: [String: CodexAppServerV2.AdditionalContextEntry] {
        [
            Self.additionalContextKey: CodexAppServerV2.AdditionalContextEntry(
                kind: .application,
                value: instruction
            )
        ]
    }

    private var instruction: String {
        switch self {
        case .text:
            "The user is currently using RemoteCoder's standard text mode. Use the normal response style rather than voice-only response styling."
        case .voice:
            "The user is currently using RemoteCoder's voice-only mode on iOS. Their speech is transcribed and may contain errors. If an apparent transcription error is clear from context or phonetic similarity, silently use the intended meaning. If the message remains unclear or materially ambiguous, say the transcription may be wrong and ask the user to repeat or rephrase it; do not guess. Respond as a natural voice assistant: concise, conversational, and direct. Preserve essential information, but omit unnecessary detail and repetition."
        }
    }
}
