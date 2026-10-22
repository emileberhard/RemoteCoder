import Foundation
import Observation

enum AppThemeStorage {
    private static let defaultThemeID: AppThemeID = .caribbeanSunset
    static let selectedThemeIDKey = "appearance.selectedThemeID"

    static func loadSelectedThemeID() -> AppThemeID {
        AppStorageScope.current.defaults.string(forKey: selectedThemeIDKey).flatMap(AppThemeID.init(rawValue:))
            ?? defaultThemeID
    }

    static func saveSelectedThemeID(_ id: AppThemeID) {
        AppStorageScope.current.defaults.set(id.rawValue, forKey: selectedThemeIDKey)
    }
}

@MainActor
@Observable
final class AppThemeStore {
    @ObservationIgnored weak var retainedTranscripts: TranscriptSurfaceRetention?
    private var appliedThemeID: AppThemeID
    var selectedThemeID: AppThemeID {
        get { appliedThemeID }
        set {
            apply(newValue)
            AppThemeStorage.saveSelectedThemeID(newValue)
        }
    }

    init() {
        appliedThemeID = AppThemeStorage.loadSelectedThemeID()
    }

    func reload() {
        apply(AppThemeStorage.loadSelectedThemeID())
    }

    private func apply(_ id: AppThemeID) {
        guard id != appliedThemeID else { return }
        retainedTranscripts?.removeAll()
        appliedThemeID = id
    }

    var theme: AppTheme {
        AppTheme.theme(for: selectedThemeID)
    }
}
