import Foundation

@MainActor
struct ConversationPinStore {
    /// Pins are per host: the same thread id on two gateways is two different
    /// conversations, and one host's rename must not retitle the other's row.
    static let legacyStorageKey = "codex.pinnedSessionNames"

    static func storageKey(hostID: UUID?) -> String {
        guard let hostID else { return legacyStorageKey }
        let key = "\(legacyStorageKey).\(hostID.uuidString)"
        return key
    }

    static func scoped(hostID: UUID?, defaults: UserDefaults) -> ConversationPinStore {
        ConversationPinStore(defaults: defaults, storageKey: storageKey(hostID: hostID))
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load() -> [String: String] {
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            result[key] = trimmed
        }
        return result
    }

    func save(_ pinnedNames: [String: String]) {
        var payload: [String: String] = [:]
        for (key, value) in pinnedNames {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            payload[key] = trimmed
        }
        if payload.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(payload, forKey: storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }
}
