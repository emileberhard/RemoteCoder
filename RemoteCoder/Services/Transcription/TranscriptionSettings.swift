import Foundation
import Observation

enum DictationVoiceSelection: String, CaseIterable, Identifiable, Sendable {
    case onlyMine
    case everyone

    var id: Self { self }
    var title: String { self == .onlyMine ? "Only Mine" : "Everyone" }
}

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case elevenLabs
    case assemblyAI
    case azureSpeech

    var id: String { rawValue }

    var name: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
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
        case .assemblyAI: .assemblyAI
        case .azureSpeech: .azure
        }
    }
}

/// How dictation audio reaches the model.
enum TranscriptionCapture: Sendable, Equatable {
    /// The finished recording is uploaded once the user stops.
    case batch
    /// PCM16 mono audio streams to the provider while recording, at the sample
    /// rate its SpeechKit `RealtimeTranscriptionSession` reports.
    case streaming

    static let batchSampleRate = 16_000
}

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    // Raw values persist in UserDefaults; retained models keep their original names.
    case elevenLabsScribeV2Realtime
    case elevenLabsScribeV2
    case assemblyAIUniversal35Pro
    case assemblyAIUniversal35ProRealtime
    case azureMAITranscribe2

    var id: String { rawValue }

    var provider: TranscriptionProvider {
        switch self {
        case .elevenLabsScribeV2Realtime, .elevenLabsScribeV2:
            .elevenLabs
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
        case .assemblyAIUniversal35Pro: "Universal-3.5 Pro"
        case .assemblyAIUniversal35ProRealtime: "Universal-3.5 Pro Realtime"
        case .azureMAITranscribe2: "MAI-Transcribe-2"
        }
    }

    var providerName: String { provider.name }

    var capture: TranscriptionCapture {
        switch self {
        case .elevenLabsScribeV2Realtime, .assemblyAIUniversal35ProRealtime: .streaming
        case .elevenLabsScribeV2, .assemblyAIUniversal35Pro, .azureMAITranscribe2: .batch
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
    var voiceChoice: DictationVoiceSelection? = nil
    var voices: DictationVoiceSelection { voiceChoice ?? TranscriptionSettings.defaultVoices(for: model) }

    static func current(defaults: UserDefaults = AppStorageScope.current.defaults) -> TranscriptionConfiguration {
        TranscriptionConfiguration(
            model: TranscriptionSettings.model(defaults: defaults),
            language: TranscriptionSettings.language(defaults: defaults),
            voiceChoice: TranscriptionSettings.voiceChoice(defaults: defaults)
        )
    }
}

enum TranscriptionSettings {
    private static let modelKey = "transcription.model"
    private static let languageKey = "transcription.language"
    private static let voicesKey = "transcription.voices"
    static let voiceForgottenAtKey = "transcription.voiceForgottenAt"
    static let syncedKeys: Set<String> = [modelKey, languageKey, voicesKey, voiceForgottenAtKey]

    static func defaultVoices(for model: TranscriptionModel) -> DictationVoiceSelection {
        model == DictationVoicePolicy.labelledModel.selection ? .onlyMine : .everyone
    }

    static func voiceChoice(defaults: UserDefaults) -> DictationVoiceSelection? {
        defaults.string(forKey: voicesKey).flatMap(DictationVoiceSelection.init(rawValue:))
    }

    static func setVoices(_ selection: DictationVoiceSelection, defaults: UserDefaults) {
        defaults.set(selection.rawValue, forKey: voicesKey)
    }

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
    @ObservationIgnored private let defaults: UserDefaults
    private var appliedModel: TranscriptionModel
    private var appliedLanguage: TranscriptionLanguage
    private var appliedVoices: DictationVoiceSelection?

    func voices(for model: TranscriptionModel) -> DictationVoiceSelection {
        appliedVoices ?? TranscriptionSettings.defaultVoices(for: model)
    }

    func setVoices(_ selection: DictationVoiceSelection) {
        appliedVoices = selection
        TranscriptionSettings.setVoices(selection, defaults: defaults)
    }

    var model: TranscriptionModel {
        get { appliedModel }
        set {
            appliedModel = newValue
            TranscriptionSettings.setModel(newValue, defaults: defaults)
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
            TranscriptionSettings.setLanguage(newValue, defaults: defaults)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appliedModel = TranscriptionSettings.model(defaults: defaults)
        appliedLanguage = TranscriptionSettings.language(defaults: defaults)
        appliedVoices = TranscriptionSettings.voiceChoice(defaults: defaults)
    }

    func reload() {
        let model = TranscriptionSettings.model(defaults: defaults)
        if model != appliedModel { appliedModel = model }
        let language = TranscriptionSettings.language(defaults: defaults)
        if language != appliedLanguage { appliedLanguage = language }
        let voices = TranscriptionSettings.voiceChoice(defaults: defaults)
        if voices != appliedVoices { appliedVoices = voices }
    }
}
