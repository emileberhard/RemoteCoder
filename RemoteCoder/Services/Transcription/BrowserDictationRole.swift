import Foundation
import Observation

@MainActor
@Observable
final class BrowserDictationRole {
    private let defaults: UserDefaults
    private static let key = "dictation.browserHost"
    private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored let host = BrowserDictationHost()
    @ObservationIgnored var onChange: (@MainActor (Bool) async -> Void)?
    @ObservationIgnored var onDrained: (@MainActor () async -> Void)?
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
                guard let self, !Task.isCancelled, enabled == selected else { return }
                await onChange?(selected)
                if !selected {
                    await host.waitUntilIdle()
                    guard !Task.isCancelled, !enabled else { return }
                    await onDrained?()
                }
                guard !Task.isCancelled, enabled == selected else { return }
                drain = nil
                updateActivity()
            }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        #if os(macOS)
        enabled = defaults.bool(forKey: Self.key)
        #else
        enabled = false
        #endif
        updateActivity()
    }

    func teardown() {
        drain?.cancel()
        drain = nil
        onChange = nil
        onDrained = nil
        #if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }

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
