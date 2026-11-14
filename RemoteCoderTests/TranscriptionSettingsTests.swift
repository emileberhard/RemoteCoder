import DictationLibrary
import Foundation
import Testing
@testable import RemoteCoder
import SpeechKit

struct TranscriptionSettingsTests {
    @Test func defaultsToElevenLabsScribeV2Realtime() {
        let suiteName = "TranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TranscriptionSettings.model(defaults: defaults) == .elevenLabsScribeV2Realtime)
    }

    @Test func removedProviderSelectionsUseTheAvailableDefault() throws {
        let suiteName = "TranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for selection in ["openAIGPT4oMini", "gemini35Flash"] {
            defaults.set(selection, forKey: "transcription.model")
            #expect(TranscriptionSettings.model(defaults: defaults) == .elevenLabsScribeV2Realtime)
        }
        #expect(TranscriptionModel(rawValue: "elevenLabsScribeV2Realtime") == .elevenLabsScribeV2Realtime)
        #expect(TranscriptionModel.azureMAITranscribe2.capture == .batch)
    }

    @Test @MainActor func choosingAProviderMovesTheModelIntoIt() {
        let store = TranscriptionSettingsStore(defaults: AppStorageScope.current.defaults)
        let original = store.model
        defer { store.model = original }

        store.model = .elevenLabsScribeV2
        #expect(store.provider == .elevenLabs)

        store.provider = .assemblyAI
        #expect(store.model == TranscriptionProvider.assemblyAI.models.first)

        // Re-selecting the current provider keeps the chosen model.
        store.model = .assemblyAIUniversal35ProRealtime
        store.provider = .assemblyAI
        #expect(store.model == .assemblyAIUniversal35ProRealtime)
    }
}

struct RealtimeTranscriptionTests {
    @Test func batchModelsHaveNoRealtimeSession() async {
        for model in TranscriptionModel.allCases {
            guard case .batch = model.capture else { continue }
            await #expect(throws: RealtimeTranscriptionError.self) {
                try await RealtimeTranscription.make(configuration: TranscriptionConfiguration(model: model, language: .automatic), access: .fixture)
            }
        }
    }

    @Test func everyStreamingModelBuildsFromGatewayAccessAtItsProviderSampleRate() async throws {
        for model in TranscriptionModel.allCases {
            guard case .streaming = model.capture else { continue }
            let transcription = try await RealtimeTranscription.make(configuration: TranscriptionConfiguration(model: model, language: .english), access: .fixture)
            #expect(transcription.session.sampleRate == 16_000, "\(model)")
        }
    }
}
