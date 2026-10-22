import Foundation
import OSLog

@MainActor
final class SyncedPreferenceStore {
    static let updateLimit = 64
    private static let valueByteLimit = 8 * 1024
    private static let stateKey = "preferenceSync.v1"

    var onReplicaChange: (@MainActor () -> Void)?
    var onExternalChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let keys: Set<String>
    private var replica: PreferenceReplica
    private var reconcileScheduled = false
    private var defaultsObservation: NotificationCenter.ObservationToken?
    private let logger = Logger(subsystem: "RemoteCoder", category: "PreferenceSync")

    var hasKeys: Bool { !keys.isEmpty }

    init(defaults: UserDefaults, keys: Set<String>) {
        precondition(keys.count <= Self.updateLimit, "synced preferences exceed one host update")
        self.defaults = defaults
        self.keys = keys
        replica = PreferenceReplica(device: UUID().uuidString.lowercased())
        if let data = defaults.data(forKey: Self.stateKey) {
            do {
                replica = try JSONDecoder().decode(PreferenceReplica.self, from: data)
            } catch {
                logger.error("Unreadable preference sync state; host values win: \(error.localizedDescription, privacy: .public)")
            }
        }
        for key in keys {
            if let value = currentValue(of: key), value != .null { replica.adopt(key, value: value) }
        }
        persist()
        reconcile()
        defaultsObservation = NotificationCenter.default.addObserver(of: defaults, for: .didChange) { [weak self] _ in
            await self?.scheduleReconcile()
        }
    }

    func merge(_ document: PreferenceDocument) {
        reconcile()
        let received = document.entries.filter { key, entry in
            guard keys.contains(key) else { return false }
            guard PreferenceEntry.syncedVersions.contains(entry.updatedAt) else {
                logger.error("Ignored preference \(key, privacy: .public): version \(entry.updatedAt, privacy: .public) is out of range")
                return false
            }
            guard entry.value == .null || entry.value.propertyList != nil else {
                logger.error("Ignored preference \(key, privacy: .public): the value cannot be stored in user defaults")
                return false
            }
            return true
        }
        let before = replica
        let changedValues = replica.merge(received)
        guard replica != before else { return }
        for (key, value) in changedValues {
            if let object = value.propertyList { defaults.set(object, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        persist()
        if !changedValues.isEmpty { onExternalChange?() }
        onReplicaChange?()
    }

    func pending(forHost document: PreferenceDocument) -> [String: PreferenceEntry] {
        reconcile()
        return replica.newer(than: document.entries).filter { key, entry in
            guard keys.contains(key) else { return false }
            guard let encoded = try? JSONEncoder().encode(entry.value), encoded.count <= Self.valueByteLimit else {
                logger.error("Preference \(key, privacy: .public) stays on this device: its value exceeds \(Self.valueByteLimit, privacy: .public) bytes")
                return false
            }
            return true
        }
    }

    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { [weak self] in
            guard let self else { return }
            reconcileScheduled = false
            reconcile()
        }
    }

    private func reconcile() {
        var changed = false
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for key in keys {
            guard let value = currentValue(of: key) else { continue }
            guard value != (replica.entries[key]?.value ?? .null) else { continue }
            replica.record(key, value: value, at: now)
            changed = true
        }
        guard changed else { return }
        persist()
        onReplicaChange?()
    }

    private func currentValue(of key: String) -> JSONValue? {
        guard let object = defaults.object(forKey: key) else { return .null }
        guard let value = JSONValue(propertyList: object) else {
            logger.error("Preference \(key, privacy: .public) holds a value that cannot sync")
            return nil
        }
        return value
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(replica), forKey: Self.stateKey)
        } catch {
            logger.error("Preference sync state write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
