import Foundation
import SpeechKit

// MARK: - Abstractions

protocol TranscriptionService: Sendable {
    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription?
    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript
}

struct RemoteCoderTranscriptionService: TranscriptionService {
    let access: GatewaySpeechAccess

    enum ServiceError: LocalizedError {
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "Transcription returned no text."
            }
        }
    }

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? {
        guard case .streaming = configuration.model.capture else { return nil }
        return try await RealtimeTranscription.make(configuration: configuration, access: access)
    }

    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript {
        let engine = try await batchEngine(for: configuration.model)
        let audio = try await recording.transcriptionAudio(
            maximumByteCount: min(engine.maximumAudioByteCount, GatewaySpeechAccess.maximumRelayedAudioByteCount)
        )
        return DictationTranscript(text: try await transcribe(audio, with: engine, configuration: configuration), model: configuration.model.batchLibraryID)
    }

    @concurrent func speakerPhrases(_ pcm16: Data, configuration: TranscriptionConfiguration,
        uploadFinished: @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase] {
        guard pcm16.count <= GatewaySpeechAccess.maximumRelayedAudioByteCount else { throw ServiceError.emptyResponse }
        let audio = try TranscriptionAudio(data: PCM16WAVFile.data(pcmData: pcm16, sampleRate: 16_000),
            fileName: "dictation.wav", mimeType: "audio/wav", fileExtension: "wav")
        do {
            let provider = AzureSpeechTranscriptionProvider(configuration: try await AzureSpeechConfiguration.make(model: .maiTranscribe2, access: access))
            return try await provider.transcribeSpeakers(.init(audio: audio, languageHints: configuration.languageHints,
                customVocabulary: configuration.customVocabulary), uploadFinished: uploadFinished)
        } catch { throw access.explain(error, provider: .azure) }
    }

    private func transcribe(_ audio: TranscriptionAudio, with engine: TranscriptionEngine,
                            configuration: TranscriptionConfiguration) async throws -> String {
        let result: TranscriptionResult
        do {
            result = try await engine.transcribe(
                TranscriptionRequest(
                    audio: audio,
                    languageHints: configuration.languageHints,
                    customVocabulary: configuration.customVocabulary,
                    instructions: nil
                )
            )
        } catch {
            throw access.explain(error, provider: configuration.model.provider.gatewayProvider)
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.emptyResponse }
        return result.text
    }

    /// Streaming models transcribe while recording; a saved dictation goes to
    /// the same provider's closest batch model instead.
    private func batchEngine(for model: TranscriptionModel) async throws -> TranscriptionEngine {
        switch model {
        case .elevenLabsScribeV2Realtime, .elevenLabsScribeV2:
            let configuration = ElevenLabsProviderConfiguration(access: try await access.access(to: .elevenLabs))
            return TranscriptionEngine(provider: ElevenLabsTranscriptionProvider(configuration: configuration))
        case .openAIGPT4oMini, .openAIGPT4oMiniTranscribeRealtime:
            return try await openAIEngine(model: "gpt-4o-mini-transcribe-2025-12-15")
        case .openAIGPT4oTranscribe, .openAIGPT4oTranscribeRealtime:
            return try await openAIEngine(model: "gpt-4o-transcribe")
        case .openAIWhisper1, .openAIRealtimeWhisper:
            return try await openAIEngine(model: "whisper-1")
        case .gemini35Flash:
            let configuration = try GeminiProviderConfiguration(
                access: try await access.access(to: .gemini),
                model: "gemini-3.5-flash"
            )
            return TranscriptionEngine(provider: GeminiTranscriptionProvider(configuration: configuration))
        case .gemini35TranscribeSmart, .gemini35TranscribeLiveSmart:
            return try await geminiTranscribeEngine(mode: .smart)
        case .gemini35TranscribeVerbatim, .gemini35TranscribeLiveVerbatim:
            return try await geminiTranscribeEngine(mode: .verbatim)
        case .assemblyAIUniversal35Pro, .assemblyAIUniversal35ProRealtime:
            let configuration = try AssemblyAIProviderConfiguration(
                access: try await access.access(to: .assemblyAI),
                pollInterval: .seconds(1)
            )
            return TranscriptionEngine(provider: AssemblyAITranscriptionProvider(configuration: configuration))
        case .azureMAITranscribe2:
            return try await azureEngine(model: .maiTranscribe2)
        }
    }

    private func openAIEngine(model: String) async throws -> TranscriptionEngine {
        let configuration = try OpenAIProviderConfiguration(access: try await access.access(to: .openAI), model: model)
        return TranscriptionEngine(provider: OpenAITranscriptionProvider(configuration: configuration))
    }

    private func geminiTranscribeEngine(mode: GeminiTranscriptionMode) async throws -> TranscriptionEngine {
        let configuration = try GeminiTranscribeProviderConfiguration(access: try await access.access(to: .gemini), mode: mode)
        return TranscriptionEngine(provider: GeminiTranscribeProvider(configuration: configuration))
    }

    /// Azure only accepts WAV/MP3/FLAC files. Saved dictations reach it as
    /// WAV; one above the upload cap, which SpeechKit exports as AAC, is
    /// rejected by the provider.
    private func azureEngine(model: AzureSpeechModel) async throws -> TranscriptionEngine {
        TranscriptionEngine(
            provider: AzureSpeechTranscriptionProvider(
                configuration: try await AzureSpeechConfiguration.make(model: model, access: access)
            )
        )
    }
}

enum AzureSpeechConfiguration {
    static func make(model: AzureSpeechModel, access: GatewaySpeechAccess) async throws -> AzureSpeechProviderConfiguration {
        try AzureSpeechProviderConfiguration(
            access: try await access.access(to: .azure),
            model: model,
            modelOptions: .init(transcribeStyle: .clean)
        )
    }
}
