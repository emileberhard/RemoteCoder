import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct SpeechPreferencesTests {
    @Test func togglePersistsForTheNextSession() throws {
        let suiteName = "SpeechPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = SpeechPreferences(defaults: defaults)
        #expect(!preferences.isAutoSpeakEnabled)
        preferences.isAutoSpeakEnabled = true

        #expect(SpeechPreferences(defaults: defaults).isAutoSpeakEnabled)
    }
}
