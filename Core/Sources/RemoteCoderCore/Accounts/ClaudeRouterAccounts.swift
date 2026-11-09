import Foundation

enum ClaudeRoute: String, Codable, Sendable { case subscription, openrouter, copilot }
enum CodexRoute: String, Codable, Sendable { case subscription, copilot }

enum ClaudeChoice: Hashable, Sendable {
    case automatic, account(String), copilot, openrouter
}

enum RouterSelection: Equatable, Sendable {
    case claude(ClaudeChoice)
    case codex(CodexRoute)
}

struct ClaudeRouterAccountList: Codable, Equatable, Sendable {
    let automatic: String
    let preference: String?
    let accounts: [ClaudeRouterAccount]
    var route: ClaudeRoute? = nil
    var codexRoute: CodexRoute? = nil
    var copilot: CopilotRouterAccount? = nil

    var choice: ClaudeChoice {
        switch route {
        case .copilot: .copilot
        case .openrouter: .openrouter
        case .subscription, nil: preference.map(ClaudeChoice.account) ?? .automatic
        }
    }

    func offers(_ selection: RouterSelection) -> Bool {
        switch selection {
        case .claude(.automatic): true
        case .claude(.account(let id)): accounts.contains { $0.id == id }
        case .claude(.copilot): copilot != nil && route != nil
        case .claude(.openrouter): false
        case .codex: copilot != nil && codexRoute != nil
        }
    }

    func confirms(_ selection: RouterSelection) -> Bool {
        switch selection {
        case .claude(let choice): self.choice == choice
        case .codex(let route): codexRoute == route
        }
    }

    func validate() throws {
        let ids = Set(accounts.map(\.id))
        guard ids.count == accounts.count, ids.contains(automatic), preference.map(ids.contains) ?? true,
              accounts.allSatisfy({ account in
                  account.windows.allSatisfy { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
              }), copilot?.budget?.isValid ?? true else { throw AccountServiceError.invalidResponse }
    }
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
            valueText: "\(remaining.formatted(Self.dollars)) of \(budget.limitUsd.formatted(Self.dollars)) left")]
    }

    var menuTitle: String {
        guard let remaining = budget?.remainingUsd else { return "Copilot" }
        return "Copilot · \(remaining.formatted(Self.dollars)) left"
    }

    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0...2))

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
    let shared: Bool
    let credential: Credential
    let availability: Availability
    let availableAt: Double?
    let windows: [AccountUsageWindow]
    let observedAt: Double?
    var resets: AccountResets? = nil

    func usageRows(now: Date) -> [CodexUsageLimitRow] {
        windows.map { window in
            let kind: UsageWindowKind = window.durationMinutes == 300 ? .fiveHour : .weekly
            return CodexUsageLimitRow(id: "claude-\(id)-\(window.id)", title: kind.label,
                usedPercent: 100 - window.remainingPercent, kind: kind,
                isStale: isUsageStale(now: now),
                resetText: window.resetText(now: now, calendar: .autoupdatingCurrent),
                runOutWarning: kind == .fiveHour ? observedAt.flatMap {
                    UsageRunOutWarning(window: window, observedAt: Date(timeIntervalSince1970: $0), now: now)
                } : nil)
        }
    }

    private func isUsageStale(now: Date) -> Bool {
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
        if [.cooling, .exhausted, .rejected].contains(availability), let availableAt {
            return "\(availability.rawValue.capitalized) until \(Date(timeIntervalSince1970: availableAt).formatted(date: .abbreviated, time: .shortened))"
        }
        return availability.rawValue.capitalized
    }

    var notice: String? {
        if credential == .rejected { return "Credential rejected" }
        if windows.isEmpty { return "Usage unavailable" }
        if isUsageStale(now: .now) { return "Last known usage" }
        return nil
    }

}

struct ClaudeRouterAccountState {
    private(set) var list: ClaudeRouterAccountList?
    var accounts: [ClaudeRouterAccount] { list?.accounts ?? [] }
    var automatic: String? { list?.automatic }
    var preference: String? { list?.preference }
    var choice: ClaudeChoice? { list?.choice }
    var codexRoute: CodexRoute? { list?.codexRoute }
    var copilot: CopilotRouterAccount? { list?.copilot }

    func offers(_ selection: RouterSelection) -> Bool { list?.offers(selection) ?? (selection == .claude(.automatic)) }

    mutating func accept(_ response: ClaudeRouterAccountList) throws {
        try response.validate()
        list = response
    }
}

struct ClaudeAccountPreference: Encodable, Sendable {
    let account: String?

    init?(_ choice: ClaudeChoice) {
        switch choice {
        case .automatic: account = nil
        case .account(let id): account = id
        case .copilot: account = "copilot"
        case .openrouter: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case account }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let account { try values.encode(account, forKey: .account) }
        else { try values.encodeNil(forKey: .account) }
    }
}
