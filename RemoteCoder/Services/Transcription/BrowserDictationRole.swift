import Foundation
import Observation

@MainActor
@Observable
final class BrowserDictationRole {
    private let defaults: UserDefaults
    private static let key = "dictation.browserHost"
    private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private let preparation: Task<Void, any Error>
    @ObservationIgnored let host = BrowserDictationHost()
    @ObservationIgnored var onChange: (@MainActor (Bool) async -> Void)?
    var holdsConnection: Bool { enabled || drain != nil }

    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Self.key)
            drain?.cancel()
            drain = nil
            let selected = enabled
            if selected { updateActivity() }
            drain = Task { [weak self, host] in
                guard let self else { return }
                await onChange?(selected)
                if !selected { await host.waitUntilIdle() }
                guard !Task.isCancelled, enabled == selected else { return }
                drain = nil
                updateActivity()
            }
        }
    }

    init(defaults: UserDefaults, storage: HostStorage) {
        self.defaults = defaults
        #if os(macOS)
        enabled = defaults.bool(forKey: Self.key)
        let directory = storage.directory(for: .device).appending(path: "browser-dictation", directoryHint: .isDirectory)
        preparation = Task { try await BrowserDictationService.sweepAtLaunch(directory) }
        #else
        enabled = false
        preparation = Task { () throws -> Void in }
        #endif
        updateActivity()
    }

    func prepare() async throws { try await preparation.value }

    private func updateActivity() {
        #if os(macOS)
        if enabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Browser dictation host")
        } else if !enabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }
}
