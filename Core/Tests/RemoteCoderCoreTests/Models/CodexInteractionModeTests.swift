import Foundation
import Testing
@testable import RemoteCoderCore

struct CodexInteractionModeTests {
    @Test
    func voiceModeProvidesApplicationScopedVoiceAssistantInstructions() throws {
        let entry = try #require(
            CodexInteractionMode.voice.additionalContext[CodexInteractionMode.additionalContextKey]
        )

        #expect(entry.kind == .application)
        #expect(
            entry.value
                == "The user is currently using RemoteCoder's voice-only mode on iOS. Their speech is transcribed and may contain errors. If an apparent transcription error is clear from context or phonetic similarity, silently use the intended meaning. If the message remains unclear or materially ambiguous, say the transcription may be wrong and ask the user to repeat or rephrase it; do not guess. Respond as a natural voice assistant: concise, conversational, and direct. Preserve essential information, but omit unnecessary detail and repetition."
        )
    }

    @Test
    func textModeExplicitlyReplacesVoiceOnlyStyling() throws {
        let entry = try #require(
            CodexInteractionMode.text.additionalContext[CodexInteractionMode.additionalContextKey]
        )

        #expect(entry.kind == .application)
        #expect(entry.value.contains("standard text mode"))
        #expect(entry.value.contains("rather than voice-only response styling"))
    }
}
