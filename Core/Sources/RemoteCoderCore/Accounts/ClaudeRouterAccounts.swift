import Foundation

struct RouterRoute: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let subscription = Self(rawValue: "subscription")
    static let chatgpt = Self(rawValue: "chatgpt")
    static let anthropic = Self(rawValue: "anthropic")
    static let copilot = Self(rawValue: "copilot")
    static let openrouter = Self(rawValue: "openrouter")

    var title: String {
        switch self {
        case .subscription: "Automatic"
        case .chatgpt: "ChatGPT"
        case .copilot: "Copilot"
        case .openrouter: "OpenRouter"
        case .anthropic: "Anthropic"
        default: rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

enum ClaudeChoice: Hashable, Sendable {
    case automatic, account(String), route(RouterRoute)

    static let copilot = Self.route(.copilot)
    static let openrouter = Self.route(.openrouter)
}

enum RouterSelection: Equatable, Sendable {
    case claude(ClaudeChoice)
    case codex(RouterRoute)
}

struct ConversationProviderChoices: Codable, Equatable, Sendable {
    let routes: [String: RouterRoute]
    let claude: [RouterRoute]
    let codex: [RouterRoute]

    func offersChoice(for thread: ConversationHeader) -> Bool {
        if routes[thread.id] != nil { return true }
        let nativeProvider = AgentProvider.provider(forThreadID: thread.id) == .claude ? "claude" : "openai"
        return (thread.modelProvider == nil || thread.modelProvider == nativeProvider)
            && !options(for: thread.id).isEmpty
    }

    func options(for threadID: String) -> [RouterRoute] {
        AgentProvider.provider(forThreadID: threadID) == .claude ? claude : codex
    }
}

struct ClaudeRouterAccountList: Codable, Equatable, Sendable {
    let automatic: String
    let preference: String?
    let accounts: [ClaudeRouterAccount]
    var models: [ClaudeModelAutomaticChoice]? = nil
    var route: RouterRoute? = nil
    var claudeRouteId: RouterRoute? = nil
    var codexRoute: RouterRoute? = nil
    var codexRouteId: RouterRoute? = nil
    var claudeRouteOptions: [RouterRoute]? = nil
    var codexRouteOptions: [RouterRoute]? = nil
    var copilot: CopilotRouterAccount? = nil

    var choice: ClaudeChoice {
        if let route = claudeRouteId ?? route, route != .subscription { return .route(route) }
        return preference.map(ClaudeChoice.account) ?? .automatic
    }

    var activeCodexRoute: RouterRoute? { codexRouteId ?? codexRoute }

    var reportsRouteOptions: Bool { claudeRouteOptions != nil || codexRouteOptions != nil }

    var selectableClaudeRoutes: [RouterRoute] {
        let routes = claudeRouteOptions ?? (copilot != nil && route != nil ? [.copilot] : [])
        return routes.filter { $0 != .subscription }
    }

    var selectableCodexRoutes: [RouterRoute] {
        codexRouteOptions ?? (copilot != nil && codexRoute != nil ? [.subscription, .copilot] : [])
    }

    func automaticMarks(for accountID: String) -> [String] {
        let choices = models ?? []
        guard choices.contains(where: { $0.automatic != automatic }) else {
            return accountID == automatic ? ["Automatic"] : []
        }
        let general = accountID == automatic ? ["Others"] : []
        return general + choices.filter { $0.automatic == accountID }.sorted { $0.model < $1.model }.map(\.title)
    }

    func offers(_ selection: RouterSelection) -> Bool {
        switch selection {
        case .claude(.automatic): true
        case .claude(.account(let id)): accounts.contains { $0.id == id }
        case .claude(.route(let route)): selectableClaudeRoutes.contains(route)
        case .codex(let route): selectableCodexRoutes.contains(route)
        }
    }

    func confirms(_ selection: RouterSelection) -> Bool {
        switch selection {
        case .claude(let choice): self.choice == choice
        case .codex(let route): activeCodexRoute == route
        }
    }

    func validate() throws {
        let ids = Set(accounts.map(\.id))
        guard [claudeRouteOptions, codexRouteOptions].allSatisfy({ routes in
                  routes.map { Set($0).count == $0.count } ?? true
              }),
              ids.count == accounts.count, ids.contains(automatic), preference.map(ids.contains) ?? true,
              models.map({ choices in
                  Set(choices.map(\.model)).count == choices.count && choices.allSatisfy {
                      !$0.model.isEmpty && ($0.automatic.map(ids.contains) ?? true)
                          && ($0.automatic == nil || $0.availableAt == nil)
                          && ($0.availableAt?.isFinite ?? true)
                  }
              }) ?? true,
              accounts.allSatisfy({ account in
                  account.windows.allSatisfy { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
              }), copilot?.budget?.isValid ?? true else { throw AccountServiceError.invalidResponse }
    }
}

struct ClaudeModelAutomaticChoice: Codable, Equatable, Sendable {
    let model: String
    let automatic: String?
    let availableAt: Double?

    var title: String { ClaudeModelCatalog.familyDisplayName(for: model) }
}

struct CopilotRouterAccount: Codable, Equatable, Sendable {
    struct Budget: Codable, Equatable, Sendable {
        let limitUsd: Double
        let spentUsd: Double?
        let remainingUsd: Double?
        let resetsAt: Double?

        var isValid: Bool {
            [limitUsd, spentUsd, remainingUsd].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true }
        }
    }

    let label: String
    let plan: String
    let availability: ClaudeRouterAccount.Availability
    let availableAt: Double?
    let error: String?
    let budget: Budget?

    func usageRows(now: Date) -> [CodexUsageLimitRow] {
        guard let budget, let spent = budget.spentUsd, let remaining = budget.remainingUsd else { return [] }
        let window = AccountUsageWindow(id: "monthly", label: UsageWindowKind.monthly.label, durationMinutes: nil,
            usedPercent: budget.limitUsd > 0 ? min(100, spent / budget.limitUsd * 100) : 100,
            resetsAt: budget.resetsAt, model: nil)
        return [CodexUsageLimitRow(id: "copilot-monthly", title: UsageWindowKind.monthly.label,
            usedPercent: 100 - window.remainingPercent, kind: .monthly,
            resetText: window.resetText(now: now, calendar: .autoupdatingCurrent),
            valueText: "\(remaining.formatted(Self.dollars)) left")]
    }

    var menuTitle: String {
        guard let remaining = budget?.remainingUsd else { return "Copilot" }
        return "Copilot · \(remaining.formatted(Self.dollars)) left"
    }

    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    var availabilityText: String {
        if availability == .exhausted, let availableAt {
            return "Exhausted until \(Date(timeIntervalSince1970: availableAt).formatted(date: .abbreviated, time: .shortened))"
        }
        return availability.rawValue.capitalized
    }

    var notice: String? {
        if let error { return error }
        if budget == nil { return "Budget unavailable" }
        return nil
    }
}

struct ClaudeRouterAccount: Codable, Equatable, Sendable, Identifiable {
    enum Credential: String, Codable, Sendable { case ready, rejected }
    let id: String
    let label: String
    enum Availability: String, Codable, Sendable { case available, cooling, exhausted, rejected, unavailable }
    let plan: String
    var tier: String? = nil
    let shared: Bool
    let credential: Credential
    let availability: Availability
    let availableAt: Double?
    let windows: [AccountUsageWindow]
    let observedAt: Double?
    var resets: AccountResets? = nil
    var models: [String]? = nil
    var cyberVerified: Bool? = nil

    var planTitle: String {
        let name = tier?.replacingOccurrences(of: "_", with: " ") ?? plan
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    func usageRows(now: Date) -> [CodexUsageLimitRow] {
        windows.map { usageRow(for: $0, now: now) }
    }

    func usageRow(for window: AccountUsageWindow, now: Date) -> CodexUsageLimitRow {
        let kind = window.kind
        return CodexUsageLimitRow(id: "claude-\(id)-\(window.id)", title: window.title,
            usedPercent: 100 - window.remainingPercent, kind: kind,
            isStale: isUsageStale(observedAt: window.observedAt ?? observedAt, now: now),
            resetText: window.resetText(now: now, calendar: .autoupdatingCurrent),
            runOutWarning: kind == .fiveHour ? observedAt.flatMap {
                UsageRunOutWarning(window: window, observedAt: Date(timeIntervalSince1970: $0), now: now)
            } : nil)
    }

    private func isUsageStale(observedAt: Double?, now: Date) -> Bool {
        guard credential == .ready, let observedAt else { return true }
        return now.timeIntervalSince1970 - observedAt > 900
    }

    func menuTitle(now: Date) -> String {
        let rows = usageRows(now: now)
        let short = rows.first { $0.kind == .fiveHour }.map { "5h \($0.remainingPercent)%" } ?? "5h —"
        let weekly = rows.first { $0.kind == .weekly }.map { "Week \($0.remainingPercent)%" } ?? "Week —"
        return "\(label) · \(short) · \(weekly)"
    }

    var availabilityText: String {
        if availability != .available, let availableAt {
            return "\(availability.rawValue.capitalized) until \(Date(timeIntervalSince1970: availableAt).formatted(date: .abbreviated, time: .shortened))"
        }
        return availability.rawValue.capitalized
    }

    var notice: String? {
        if credential == .rejected { return "Credential rejected" }
        if windows.isEmpty { return "Usage unavailable" }
        if isUsageStale(observedAt: observedAt, now: .now) { return "Last known usage" }
        return nil
    }

}

struct ClaudeRouterAccountState {
    private(set) var list: ClaudeRouterAccountList?
    var accounts: [ClaudeRouterAccount] { list?.accounts ?? [] }
    var automatic: String? { list?.automatic }
    var preference: String? { list?.preference }
    var choice: ClaudeChoice? { list?.choice }
    var codexRoute: RouterRoute? { list?.activeCodexRoute }
    var codexRoutes: [RouterRoute] { list?.selectableCodexRoutes ?? [] }
    var claudeRoutes: [RouterRoute] { list?.selectableClaudeRoutes ?? [] }
    var copilot: CopilotRouterAccount? { list?.copilot }

    func offers(_ selection: RouterSelection) -> Bool { list?.offers(selection) ?? (selection == .claude(.automatic)) }

    func offeredModels(_ options: [ModelOption], keeping selected: ModelOption?) -> [ModelOption] {
        guard case .account(let id)? = choice, let models = accounts.first(where: { $0.id == id })?.models else { return options }
        return options.filter {
            $0.provider != .claude || $0.modelProvider != nil || $0.id == selected?.id
                || models.contains(ClaudeModelCatalog.canonicalModelID($0.id))
        }
    }

    mutating func accept(_ response: ClaudeRouterAccountList) throws {
        try response.validate()
        list = response
    }
}

struct ClaudeAccountPreference: Encodable, Sendable {
    let account: String?

    let route: RouterRoute?

    init(_ choice: ClaudeChoice) {
        switch choice {
        case .automatic: (account, route) = (nil, nil)
        case .account(let id): (account, route) = (id, nil)
        case .route(.copilot): (account, route) = ("copilot", nil)
        case .route(let route): (account, self.route) = (nil, route)
        }
    }

    private enum CodingKeys: String, CodingKey { case account, route }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let route { try values.encode(route, forKey: .route) }
        else if let account { try values.encode(account, forKey: .account) }
        else { try values.encodeNil(forKey: .account) }
    }
}
