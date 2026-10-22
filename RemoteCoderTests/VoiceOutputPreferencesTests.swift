import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct VoiceOutputPreferencesTests {
    @Test func controllersUseCurrentPreferenceAfterConstruction() throws {
        let suiteName = "VoiceOutputPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SpeechPreferences(defaults: defaults)
        let visible = VoiceOutputController(access: .fixture, preferences: preferences)
        let hidden = VoiceOutputController(access: .fixture, preferences: preferences)

        hidden.enqueue("Initially disabled")
        #expect(!hidden.isPreparing)

        preferences.isAutoSpeakEnabled = true
        hidden.enqueue("Enabled after construction")
        #expect(hidden.isPreparing)
        hidden.cancel()

        preferences.isAutoSpeakEnabled = false
        visible.enqueue("Disabled again")
        #expect(!visible.isPreparing)
    }
}
