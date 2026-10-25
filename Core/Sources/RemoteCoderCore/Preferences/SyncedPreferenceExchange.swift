import Foundation
import OSLog

protocol SyncedPreferenceRemote: Actor {
    func readPreferences() async throws -> PreferenceDocument
    func updatePreferences(_ entries: [String: PreferenceEntry]) async throws -> PreferenceDocument
}

@MainActor
final class SyncedPreferenceExchange {
    private let gateway: any SyncedPreferenceRemote
    private let store: SyncedPreferenceStore
    private let hostLabel: String
    private var task: Task<Void, Never>?
    private var requested = false
    private var isRetired = false
    private let logger = AppLogger(category: "PreferenceSync")

    init(gateway: any SyncedPreferenceRemote, store: SyncedPreferenceStore, hostLabel: String) {
        self.gateway = gateway
        self.store = store
        self.hostLabel = hostLabel
    }

    @discardableResult
    func sync() -> Task<Void, Never>? {
        guard !isRetired, store.hasKeys else { return nil }
        requested = true
        if let task { return task }
        let task = Task { [weak self] in
            guard let self else { return }
            await run()
        }
        self.task = task
        return task
    }

    func receive(_ document: PreferenceDocument) {
        guard !isRetired, store.hasKeys else { return }
        store.merge(document)
        if !store.pending(forHost: document).isEmpty { sync() }
    }

    func retire() -> Task<Void, Never>? {
        isRetired = true
        task?.cancel()
        return task
    }

    private func run() async {
        defer { task = nil }
        while requested, !isRetired {
            requested = false
            do {
                let document = try await gateway.readPreferences()
                guard !isRetired else { return }
                store.merge(document)
                let pending = store.pending(forHost: document)
                guard !pending.isEmpty else { continue }
                let updated = try await gateway.updatePreferences(pending)
                guard !isRetired else { return }
                store.merge(updated)
            } catch {
                logger.notice("Preference sync failed host=\(self.hostLabel): \(error.localizedDescription)")
                if !requested { return }
            }
        }
    }
}
