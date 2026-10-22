import Foundation
import Observation

@MainActor
@Observable
final class SpeechPreferences {
    static let shared = SpeechPreferences()
    static let autoSpeakKey = "ttsAutoSpeakEnabled"

    @ObservationIgnored private let defaults: UserDefaults
    private var autoSpeaks: Bool
    var isAutoSpeakEnabled: Bool {
        get { autoSpeaks }
        set {
            guard newValue != autoSpeaks else { return }
            autoSpeaks = newValue
            defaults.set(newValue, forKey: Self.autoSpeakKey)
        }
    }

    init(defaults: UserDefaults = AppStorageScope.current.defaults) {
        self.defaults = defaults
        autoSpeaks = defaults.bool(forKey: Self.autoSpeakKey)
    }

    func reload() {
        let stored = defaults.bool(forKey: Self.autoSpeakKey)
        if stored != autoSpeaks { autoSpeaks = stored }
    }
}
