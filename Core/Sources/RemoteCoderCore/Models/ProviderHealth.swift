import Foundation

enum ProviderStatus: Sendable, Equatable {
    case ready
    case fallback(route: String, reason: String)
    case unavailable(reason: String)

    var isBroken: Bool { self != .ready }

    var reason: String? {
        switch self {
        case .ready: nil
        case .fallback(_, let reason), .unavailable(let reason): reason
        }
    }
}

struct ProviderHealth: Sendable, Equatable {
    private let statuses: [AgentProvider: ProviderStatus]

    init(_ statuses: [AgentProvider: ProviderStatus]) {
        self.statuses = statuses
    }

    func status(of provider: AgentProvider) -> ProviderStatus? {
        statuses[provider]
    }

    private func isUnavailable(_ provider: AgentProvider) -> Bool {
        if case .unavailable = statuses[provider] { true } else { false }
    }

    var workingProviders: Set<AgentProvider> {
        Set(AgentProvider.allCases.filter { !isUnavailable($0) })
    }

    func isImpaired(_ model: ModelOption) -> Bool {
        switch statuses[model.provider] {
        case .unavailable: true
        case .fallback: model.modelProvider == nil
        case .ready, nil: false
        }
    }

    func warning(for model: ModelOption, isNewChat: Bool) -> String? {
        guard isImpaired(model), let status = statuses[model.provider] else { return nil }
        if case .fallback(let route, _) = status, isNewChat { return "New chats run on \(ThreadModelProvider.displayName(of: route))" }
        return status.reason
    }

    func switchNotice(preferred: AgentProvider, selected: AgentProvider) -> String? {
        guard preferred != selected, case .unavailable(let reason) = statuses[preferred] else { return nil }
        return reason
    }
}

extension ProviderHealth: Decodable {
    private struct Entry: Decodable {
        let state: String
        let reason: String?
        let fallback: String?

        var status: ProviderStatus? {
            switch (state, reason, fallback) {
            case ("ready", _, _): .ready
            case ("fallback", let reason?, let route?): .fallback(route: route, reason: reason)
            case ("unavailable", let reason?, _): .unavailable(reason: reason)
            default: nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let entries = try [String: Entry](from: decoder)
        statuses = entries.reduce(into: [:]) { statuses, entry in
            guard let provider = AgentProvider(rawValue: entry.key), let status = entry.value.status else { return }
            statuses[provider] = status
        }
    }
}
