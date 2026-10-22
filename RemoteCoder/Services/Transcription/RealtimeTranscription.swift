import Foundation
import SpeechKit

enum RealtimeTranscriptionError: LocalizedError, Sendable {
    case notStreaming(TranscriptionModel)

    var errorDescription: String? {
        switch self {
        case .notStreaming(let model):
            "\(model.name) transcribes the finished recording, not a live stream."
        }
    }
}

struct RealtimeTranscription: Sendable {
    let session: any RealtimeTranscriptionSession
    let provider: GatewaySpeechProvider

    static func make(
        configuration: TranscriptionConfiguration,
        access: GatewaySpeechAccess
    ) async throws -> RealtimeTranscription {
        RealtimeTranscription(
            session: try await session(for: configuration.model, configuration: configuration, access: access),
            provider: configuration.model.provider.gatewayProvider
        )
    }

    private static func session(
        for model: TranscriptionModel,
        configuration: TranscriptionConfiguration,
        access: GatewaySpeechAccess
    ) async throws -> any RealtimeTranscriptionSession {
        switch model {
        case .elevenLabsScribeV2Realtime:
            let configuration = try ElevenLabsRealtimeSessionConfiguration(
                access: try await access.access(to: .elevenLabs),
                keyterms: ElevenLabsRealtimeSessionConfiguration.compatibleKeyterms(from: configuration.customVocabulary),
                languageHints: configuration.languageHints,
                includeTimestamps: false,
                commitStrategy: .vad
            )
            return ElevenLabsRealtimeSession(configuration: configuration)
        case .openAIRealtimeWhisper:
            return try await openAI(modelID: "gpt-realtime-whisper", configuration: configuration, access: access)
        case .openAIGPT4oTranscribeRealtime:
            return try await openAI(modelID: "gpt-4o-transcribe", configuration: configuration, access: access)
        case .openAIGPT4oMiniTranscribeRealtime:
            return try await openAI(modelID: "gpt-4o-mini-transcribe", configuration: configuration, access: access)
        case .gemini35TranscribeLiveSmart:
            return try await gemini(mode: .smart, configuration: configuration, access: access)
        case .gemini35TranscribeLiveVerbatim:
            return try await gemini(mode: .verbatim, configuration: configuration, access: access)
        case .assemblyAIUniversal35ProRealtime:
            let configuration = try AssemblyAIRealtimeSessionConfiguration(
                access: try await access.access(to: .assemblyAI),
                keyterms: AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(from: configuration.customVocabulary),
                languageHints: configuration.languageHints
            )
            return AssemblyAIRealtimeSession(configuration: configuration)
        case .azureMAITranscribe2:
            let azure = AzureSpeechTranscriptionProvider(
                configuration: try await AzureSpeechConfiguration.make(model: .maiTranscribe2, access: access)
            )
            return ProgressiveRealtimeTranscriptionSession(
                provider: azure,
                request: ProgressiveTranscriptionRequest(languageHints: configuration.languageHints, customVocabulary: configuration.customVocabulary)
            )
        case .elevenLabsScribeV2,
             .openAIGPT4oMini, .openAIGPT4oTranscribe, .openAIWhisper1,
             .gemini35Flash, .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
             .assemblyAIUniversal35Pro:
            throw RealtimeTranscriptionError.notStreaming(model)
        }
    }

    private static func openAI(
        modelID: String,
        configuration: TranscriptionConfiguration,
        access: GatewaySpeechAccess
    ) async throws -> any RealtimeTranscriptionSession {
        // gpt-realtime-whisper only transcribes on an explicit commit; the
        // gpt-4o family can commit on its own as speech pauses, which keeps
        // the stop latency short for long dictations.
        let isRealtimeWhisper = modelID.hasPrefix("gpt-realtime-whisper")
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: try await access.access(to: .openAI),
            modelID: modelID,
            customVocabulary: OpenAIRealtimeSessionConfiguration.supportsCustomVocabulary(modelID: modelID) ? configuration.customVocabulary : [],
            languageHints: configuration.languageHints,
            turnDetection: isRealtimeWhisper ? .disabled : .semanticVAD(eagerness: .low),
            transcriptionDelay: isRealtimeWhisper ? .high : nil,
            noiseReduction: .nearField
        )
        return OpenAIRealtimeSession(configuration: configuration)
    }

    private static func gemini(
        mode: GeminiTranscriptionMode,
        configuration: TranscriptionConfiguration,
        access: GatewaySpeechAccess
    ) async throws -> any RealtimeTranscriptionSession {
        let configuration = try GeminiRealtimeSessionConfiguration(
            access: try await access.access(to: .gemini),
            customVocabulary: configuration.customVocabulary,
            languageHints: configuration.languageHints,
            mode: mode
        )
        return GeminiRealtimeSession(configuration: configuration)
    }
}
