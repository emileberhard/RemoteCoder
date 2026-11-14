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
        case .assemblyAIUniversal35ProRealtime:
            let configuration = try AssemblyAIRealtimeSessionConfiguration(
                access: try await access.access(to: .assemblyAI),
                keyterms: AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(from: configuration.customVocabulary),
                languageHints: configuration.languageHints
            )
            return AssemblyAIRealtimeSession(configuration: configuration)
        case .elevenLabsScribeV2, .assemblyAIUniversal35Pro, .azureMAITranscribe2:
            throw RealtimeTranscriptionError.notStreaming(model)
        }
    }
}
