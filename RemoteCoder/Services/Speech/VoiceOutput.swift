import Foundation
import Observation
import OSLog
import SpeechKit

enum SpeechOutputDefaults {
    static let model: GeminiSpeechSynthesisModel = .flash31Preview
    static let voice: GeminiSpeechVoice = .achird
    static let instructions = """
        Sound friendly, casual, and natural, like a helpful general-purpose voice assistant. Adapt the response into flowing spoken language. Do not read Markdown syntax, raw URLs, code, diffs, or terminal output aloud. For a link, say "Open the chat to see the link." For code or other technical details, briefly summarize them and say the details are available in the chat.
        """

    static func request(text: String) throws -> SpeechSynthesisRequest<GeminiSpeechSynthesisOptions> {
        SpeechSynthesisRequest(
            text: text,
            options: try GeminiSpeechSynthesisOptions(
                model: model,
                voice: voice,
                instructions: instructions
            )
        )
    }
}

@MainActor
@Observable
final class VoiceOutputController {
    private let access: GatewaySpeechAccess
    private let preferences: SpeechPreferences
    @ObservationIgnored private var synthesizer: (access: SpeechProviderAccess, synthesizer: SpeechSynthesizer<GeminiSpeechSynthesisProvider>)?
    private let logger = Logger(subsystem: "RemoteCoder", category: "VoiceOutput")

    private var currentTask: Task<Void, Never>?
    private var activeUtteranceID = UUID()
    var isPreparing = false
    var isSpeaking = false
    private(set) var lastError: String?

    init(access: GatewaySpeechAccess, preferences: SpeechPreferences = .shared) {
        self.access = access
        self.preferences = preferences
    }

    func dismissError() {
        lastError = nil
    }

    func enqueue(_ text: String) {
        guard preferences.isAutoSpeakEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousTask = currentTask
        previousTask?.cancel()

        let utteranceID = UUID()
        activeUtteranceID = utteranceID
        lastError = nil
        isPreparing = true
        isSpeaking = false

        currentTask = Task { [weak self] in
            await previousTask?.value
            guard let self, self.activeUtteranceID == utteranceID else { return }
            await self.speak(trimmed, utteranceID: utteranceID)
        }
    }

    func cancel() {
        activeUtteranceID = UUID()
        currentTask?.cancel()
        isPreparing = false
        isSpeaking = false
    }
}

private extension VoiceOutputController {
    func speak(
        _ text: String,
        utteranceID: UUID
    ) async {
        do {
            let synthesizer = try await currentSynthesizer()
            try Task.checkCancellation()
            guard activeUtteranceID == utteranceID else { throw CancellationError() }

            try await synthesizer.speak(
                SpeechOutputDefaults.request(text: text),
                playback: .spokenAudio,
                onPlaybackStarted: { [weak self] in
                    await self?.playbackDidStart(utteranceID: utteranceID)
                }
            )
            guard activeUtteranceID == utteranceID else { return }
            isPreparing = false
            isSpeaking = false
            currentTask = nil
        } catch is CancellationError {
            guard activeUtteranceID == utteranceID else { return }
            isPreparing = false
            isSpeaking = false
            currentTask = nil
        } catch {
            let error = access.explain(error, provider: .gemini)
            logger.error("Voice output failed: \(error.localizedDescription, privacy: .public)")
            guard activeUtteranceID == utteranceID else { return }
            lastError = error.localizedDescription
            isPreparing = false
            isSpeaking = false
            currentTask = nil
        }
    }

    func currentSynthesizer() async throws -> SpeechSynthesizer<GeminiSpeechSynthesisProvider> {
        let access = try await access.access(to: .gemini)
        if let synthesizer, synthesizer.access == access { return synthesizer.synthesizer }
        let made = SpeechSynthesizer(
            provider: GeminiSpeechSynthesisProvider(configuration: try GeminiSpeechSynthesisConfiguration(access: access))
        )
        synthesizer = (access, made)
        return made
    }

    func playbackDidStart(utteranceID: UUID) {
        guard activeUtteranceID == utteranceID else { return }
        isPreparing = false
        isSpeaking = true
    }
}
