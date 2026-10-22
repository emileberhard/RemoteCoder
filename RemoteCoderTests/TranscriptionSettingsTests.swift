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

    @Test func sharedVerbatimPreferencesRemainEffectiveWhenArchivingIsOff() throws {
        let smart = TranscriptionModel.gemini35TranscribeLiveSmart
        let verbatim = TranscriptionModel.gemini35TranscribeLiveVerbatim
        #expect(verbatim.libraryID == "google/gemini-3.5-transcribe-live/realtime?mode=verbatim")
        let profile = DictationProfile(archiveEnabled: false, preferredModel: verbatim.libraryID,
            languages: ["de", "sv"], dictionary: ["RemoteCoder"], cleanupEnabled: true,
            outputLanguage: nil, thinkingLevel: "minimal")
        let plan = DictationPlan(unverifiedProfile: profile, context: .chat,
            capabilities: try DictationCapabilities(models: [smart.libraryID, verbatim.libraryID],
                fallbackModel: smart.libraryID, supportsCleanup: true,
                modelOptions: [smart.libraryID: smart.libraryOptions, verbatim.libraryID: verbatim.libraryOptions]))
        let configuration = try TranscriptionConfiguration(plan: plan,
            local: TranscriptionConfiguration(model: smart, language: .english))
        #expect(configuration.model == verbatim)
        #expect(configuration.languageHints == ["de", "sv"])
        #expect(configuration.customVocabulary == ["RemoteCoder"])
        #expect(!plan.archiveEnabled)
        #expect(plan.cleanupEnabled)
    }

    @Test func selectionsSavedBeforeTheProviderPickerStillResolve() {
        // These raw values were persisted by earlier builds and must keep decoding.
        #expect(TranscriptionModel(rawValue: "elevenLabsScribeV2Realtime") == .elevenLabsScribeV2Realtime)
        #expect(TranscriptionModel(rawValue: "openAIGPT4oMini") == .openAIGPT4oMini)
        #expect(TranscriptionModel(rawValue: "gemini35Flash") == .gemini35Flash)
    }

    @Test @MainActor func choosingAProviderMovesTheModelIntoIt() {
        let store = TranscriptionSettingsStore()
        let original = store.model
        defer { store.model = original }

        store.model = .openAIGPT4oTranscribe
        #expect(store.provider == .openAI)

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
            #expect(transcription.session.sampleRate == (model.provider == .openAI ? 24_000 : 16_000), "\(model)")
        }
    }
}
