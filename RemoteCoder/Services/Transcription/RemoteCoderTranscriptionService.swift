import Foundation
import SpeechKit

// MARK: - Abstractions

protocol TranscriptionService: Sendable {
    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription?
    @concurrent func speakerPhrases(_ pcm16: Data, configuration: TranscriptionConfiguration,
        uploadFinished: @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase]
    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript
}

struct RemoteCoderTranscriptionService: TranscriptionService {
    let access: GatewaySpeechAccess

    enum ServiceError: LocalizedError {
        case emptyResponse
        case audioTooLarge

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "Transcription returned no text."
            case .audioTooLarge:
                return "The recording exceeds the dictation audio limit."
            }
        }
    }

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? {
        guard case .streaming = configuration.model.capture else { return nil }
        return try await RealtimeTranscription.make(configuration: configuration, access: access)
    }

    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript {
        do {
            return try await access.perform { providerAccess in
                let engine = try batchEngine(for: configuration.model, access: providerAccess)
                let audio = try await DictationUploadAudio.recording(recording,
                    model: configuration.model, maximumByteCount: min(engine.maximumAudioByteCount, GatewaySpeechAccess.maximumAudioByteCount))
                return DictationTranscript(text: try await transcribe(audio, with: engine, configuration: configuration), model: configuration.model.batchLibraryID)
            }
        } catch {
            throw access.explain(error, provider: configuration.model.provider.gatewayProvider)
        }
    }

    @concurrent func speakerPhrases(_ pcm16: Data, configuration: TranscriptionConfiguration,
        uploadFinished: @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase] {
        let audio = try DictationUploadAudio.speakers(pcm16)
        guard audio.data.count <= GatewaySpeechAccess.maximumAudioByteCount else { throw ServiceError.audioTooLarge }
        return try await access.perform { providerAccess in
            let provider = AzureSpeechTranscriptionProvider(configuration: try AzureSpeechConfiguration.make(access: providerAccess))
            return try await provider.transcribeSpeakers(.init(audio: audio, languageHints: configuration.languageHints,
                customVocabulary: configuration.customVocabulary), uploadFinished: uploadFinished)
        }
    }

    private func transcribe(_ audio: TranscriptionAudio, with engine: TranscriptionEngine,
                            configuration: TranscriptionConfiguration) async throws -> String {
        let result = try await engine.transcribe(
            TranscriptionRequest(audio: audio, languageHints: configuration.languageHints,
                customVocabulary: configuration.customVocabulary, instructions: nil)
        )
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.emptyResponse }
        return result.text
    }

    /// Streaming models transcribe while recording; a saved dictation goes to
    /// the same provider's closest batch model instead.
    private func batchEngine(for model: TranscriptionModel, access: SpeechProviderAccess) throws -> TranscriptionEngine {
        switch model {
        case .elevenLabsScribeV2Realtime, .elevenLabsScribeV2:
            let configuration = ElevenLabsProviderConfiguration(access: access)
            return TranscriptionEngine(provider: ElevenLabsTranscriptionProvider(configuration: configuration))
        case .assemblyAIUniversal35Pro, .assemblyAIUniversal35ProRealtime:
            let configuration = try AssemblyAIProviderConfiguration(access: access, pollInterval: .seconds(1))
            return TranscriptionEngine(provider: AssemblyAITranscriptionProvider(configuration: configuration))
        case .azureMAITranscribe2:
            return TranscriptionEngine(provider: AzureSpeechTranscriptionProvider(configuration: try AzureSpeechConfiguration.make(access: access)))
        }
    }
}

enum AzureSpeechConfiguration {
    static func make(access: SpeechProviderAccess) throws -> AzureSpeechProviderConfiguration {
        try AzureSpeechProviderConfiguration(access: access, model: .maiTranscribe2,
            modelOptions: .init(transcribeStyle: .clean))
    }
}

enum DictationUploadAudio {
    static func recording(_ recording: DictationRecording<ExecutionTarget>, model: TranscriptionModel,
                          maximumByteCount: Int) async throws -> TranscriptionAudio {
        if model.provider == .azureSpeech {
            return try await recording.flacAudio(maximumByteCount: maximumByteCount)
        }
        return try await recording.transcriptionAudio(maximumByteCount: maximumByteCount)
    }

    static func speakers(_ pcm16: Data) throws -> TranscriptionAudio {
        try TranscriptionAudio(data: PCM16FLACFile.data(pcmData: pcm16, sampleRate: 16_000),
            fileName: "dictation.flac", mimeType: "audio/flac", fileExtension: "flac")
    }
}
