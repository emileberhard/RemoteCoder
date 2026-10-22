import Foundation
import Observation

@Observable @MainActor
final class AccountNameStore {
    static let storageKey = "accounts.names-by-group.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onRename: (@MainActor () -> Void)?
    private var nicknames: [String: String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        nicknames = Self.load(defaults)
    }

    func reload() {
        let stored = Self.load(defaults)
        guard stored != nicknames else { return }
        nicknames = stored
        onRename?()
    }

    private static func load(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func displayName(provider: AgentProvider, identity: ProviderAccountIdentity?) -> String {
        identity.flatMap { nickname(provider: provider, identity: $0) } ?? defaultName(provider: provider, identity: identity)
    }

    func defaultName(provider: AgentProvider, identity: ProviderAccountIdentity?) -> String {
        identity?.email ?? "\(provider.displayName) account"
    }

    func nickname(provider: AgentProvider, identity: ProviderAccountIdentity) -> String? {
        nicknames[provider.groupID(for: identity)]
    }

    func rename(provider: AgentProvider, identity: ProviderAccountIdentity, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[provider.groupID(for: identity)] = trimmed.isEmpty ? nil : trimmed
        defaults.set(nicknames, forKey: Self.storageKey)
        onRename?()
    }
}
