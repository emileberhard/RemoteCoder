import Foundation
import Observation

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case elevenLabs
    case openAI
    case gemini
    case assemblyAI
    case azureSpeech

    var id: String { rawValue }

    var name: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .assemblyAI: "AssemblyAI"
        case .azureSpeech: "Azure Speech"
        }
    }

    var models: [TranscriptionModel] {
        TranscriptionModel.allCases.filter { $0.provider == self }
    }

    var gatewayProvider: GatewaySpeechProvider {
        switch self {
        case .elevenLabs: .elevenLabs
        case .openAI: .openAI
        case .gemini: .gemini
        case .assemblyAI: .assemblyAI
        case .azureSpeech: .azure
        }
    }
}

/// How dictation audio reaches the model.
enum TranscriptionCapture: Sendable {
    /// The finished recording is uploaded once the user stops.
    case batch
    /// PCM16 mono audio streams to the provider while recording, at the sample
    /// rate its SpeechKit `RealtimeTranscriptionSession` reports.
    case streaming

    static let batchSampleRate = 16_000
}

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    // Raw values persist in UserDefaults; the three that predate the provider
    // picker keep their original names so saved selections survive.
    case elevenLabsScribeV2Realtime
    case elevenLabsScribeV2
    case openAIGPT4oMini
    case openAIGPT4oTranscribe
    case openAIWhisper1
    case openAIRealtimeWhisper
    case openAIGPT4oTranscribeRealtime
    case openAIGPT4oMiniTranscribeRealtime
    case gemini35Flash
    case gemini35TranscribeSmart
    case gemini35TranscribeVerbatim
    case gemini35TranscribeLiveSmart
    case gemini35TranscribeLiveVerbatim
    case assemblyAIUniversal35Pro
    case assemblyAIUniversal35ProRealtime
    case azureMAITranscribe2

    var id: String { rawValue }

    var provider: TranscriptionProvider {
        switch self {
        case .elevenLabsScribeV2Realtime, .elevenLabsScribeV2:
            .elevenLabs
        case .openAIGPT4oMini, .openAIGPT4oTranscribe, .openAIWhisper1,
             .openAIRealtimeWhisper, .openAIGPT4oTranscribeRealtime, .openAIGPT4oMiniTranscribeRealtime:
            .openAI
        case .gemini35Flash, .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
             .gemini35TranscribeLiveSmart, .gemini35TranscribeLiveVerbatim:
            .gemini
        case .assemblyAIUniversal35Pro, .assemblyAIUniversal35ProRealtime:
            .assemblyAI
        case .azureMAITranscribe2:
            .azureSpeech
        }
    }

    var name: String {
        switch self {
        case .elevenLabsScribeV2Realtime: "Scribe v2 Realtime"
        case .elevenLabsScribeV2: "Scribe v2"
        case .openAIGPT4oMini: "GPT-4o Mini Transcribe"
        case .openAIGPT4oTranscribe: "GPT-4o Transcribe"
        case .openAIWhisper1: "Whisper"
        case .openAIRealtimeWhisper: "GPT Realtime Whisper"
        case .openAIGPT4oTranscribeRealtime: "GPT-4o Transcribe Realtime"
        case .openAIGPT4oMiniTranscribeRealtime: "GPT-4o Mini Transcribe Realtime"
        case .gemini35Flash: "Gemini 3.5 Flash"
        case .gemini35TranscribeSmart: "Gemini 3.5 Transcribe (Smart)"
        case .gemini35TranscribeVerbatim: "Gemini 3.5 Transcribe (Verbatim)"
        case .gemini35TranscribeLiveSmart: "Gemini 3.5 Transcribe Live (Smart)"
        case .gemini35TranscribeLiveVerbatim: "Gemini 3.5 Transcribe Live (Verbatim)"
        case .assemblyAIUniversal35Pro: "Universal-3.5 Pro"
        case .assemblyAIUniversal35ProRealtime: "Universal-3.5 Pro Realtime"
        case .azureMAITranscribe2: "MAI-Transcribe-2"
        }
    }

    var providerName: String { provider.name }

    var capture: TranscriptionCapture {
        switch self {
        case .elevenLabsScribeV2Realtime,
             .openAIRealtimeWhisper, .openAIGPT4oTranscribeRealtime, .openAIGPT4oMiniTranscribeRealtime,
             .gemini35TranscribeLiveSmart, .gemini35TranscribeLiveVerbatim,
             .assemblyAIUniversal35ProRealtime:
            .streaming
        case .azureMAITranscribe2:
            // Azure uploads the recording progressively while it records, so a
            // stop waits only for the transcription.
            .streaming
        case .elevenLabsScribeV2,
             .openAIGPT4oMini, .openAIGPT4oTranscribe, .openAIWhisper1,
             .gemini35Flash, .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
             .assemblyAIUniversal35Pro:
            .batch
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case english
    case swedish
    case englishAndSwedish

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .english:
            return "English"
        case .swedish:
            return "Swedish"
        case .englishAndSwedish:
            return "English & Swedish"
        }
    }

    var hints: [String] {
        switch self {
        case .automatic:
            return []
        case .english:
            return ["en"]
        case .swedish:
            return ["sv"]
        case .englishAndSwedish:
            return ["en", "sv"]
        }
    }
}

/// The model/language a recording was started with, captured once so a later
/// transcription never picks up a setting the user changed in between.
struct TranscriptionConfiguration: Sendable {
    let model: TranscriptionModel
    let language: TranscriptionLanguage
    var languageHints: [String] { sharedLanguages ?? language.hints }
    var customVocabulary: [String] = []
    var sharedLanguages: [String]? = nil

    static func current(defaults: UserDefaults = AppStorageScope.current.defaults) -> TranscriptionConfiguration {
        TranscriptionConfiguration(
            model: TranscriptionSettings.model(defaults: defaults),
            language: TranscriptionSettings.language(defaults: defaults)
        )
    }
}

enum TranscriptionSettings {
    private static let modelKey = "transcription.model"
    private static let languageKey = "transcription.language"
    static let syncedKeys: Set<String> = [modelKey, languageKey]

    static func model(defaults: UserDefaults = AppStorageScope.current.defaults) -> TranscriptionModel {
        defaults.string(forKey: modelKey)
            .flatMap(TranscriptionModel.init(rawValue:))
            ?? .elevenLabsScribeV2Realtime
    }

    static func setModel(_ model: TranscriptionModel, defaults: UserDefaults = AppStorageScope.current.defaults) {
        defaults.set(model.rawValue, forKey: modelKey)
    }

    static func language(defaults: UserDefaults = AppStorageScope.current.defaults) -> TranscriptionLanguage {
        defaults.string(forKey: languageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:))
            ?? .automatic
    }

    static func setLanguage(_ language: TranscriptionLanguage, defaults: UserDefaults = AppStorageScope.current.defaults) {
        defaults.set(language.rawValue, forKey: languageKey)
    }
}

@MainActor
@Observable
final class TranscriptionSettingsStore {
    private var appliedModel: TranscriptionModel
    private var appliedLanguage: TranscriptionLanguage

    var model: TranscriptionModel {
        get { appliedModel }
        set {
            appliedModel = newValue
            TranscriptionSettings.setModel(newValue)
        }
    }

    /// The model owns the selection; choosing another provider moves the
    /// selection to that provider's first model.
    var provider: TranscriptionProvider {
        get { model.provider }
        set {
            guard newValue != model.provider, let first = newValue.models.first else { return }
            model = first
        }
    }

    var language: TranscriptionLanguage {
        get { appliedLanguage }
        set {
            appliedLanguage = newValue
            TranscriptionSettings.setLanguage(newValue)
        }
    }

    init() {
        appliedModel = TranscriptionSettings.model()
        appliedLanguage = TranscriptionSettings.language()
    }

    func reload() {
        let model = TranscriptionSettings.model()
        if model != appliedModel { appliedModel = model }
        let language = TranscriptionSettings.language()
        if language != appliedLanguage { appliedLanguage = language }
    }
}
