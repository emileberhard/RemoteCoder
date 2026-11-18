import Foundation
import Observation

@MainActor
@Observable
final class BrowserDictationRole {
    private let defaults: UserDefaults
    private static let key = "dictation.browserHost"
    private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored let host = BrowserDictationHost()
    @ObservationIgnored let files: BrowserDictationFiles
    @ObservationIgnored var onChange: (@MainActor (Bool, Int) async -> Void)?
    @ObservationIgnored var onDrained: (@MainActor (Int) async -> Void)?
    var holdsConnection: Bool { enabled || drain != nil }

    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Self.key)
            drain?.cancel()
            drain = nil
            let selected = enabled
            revision += 1
            let revision = revision
            if selected { updateActivity() }
            drain = Task { [weak self, host] in
                guard let self, !Task.isCancelled, isCurrent(revision, enabled: selected) else { return }
                await onChange?(selected, revision)
                guard !Task.isCancelled, isCurrent(revision, enabled: selected) else { return }
                if !selected {
                    await host.waitUntilIdle()
                    guard !Task.isCancelled, isCurrent(revision, enabled: false) else { return }
                    await onDrained?(revision)
                }
                guard !Task.isCancelled, isCurrent(revision, enabled: selected) else { return }
                drain = nil
                updateActivity()
            }
        }
    }

    init(defaults: UserDefaults, storage: HostStorage) {
        self.defaults = defaults
        files = BrowserDictationFiles(directory: storage.directory(for: .device).appending(path: "browser-dictation", directoryHint: .isDirectory))
        #if os(macOS)
        enabled = defaults.bool(forKey: Self.key)
        #else
        enabled = false
        #endif
        updateActivity()
    }

    func isCurrent(_ revision: Int, enabled: Bool) -> Bool {
        self.revision == revision && self.enabled == enabled
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
