import Foundation

struct ClaudeRouterAccountList: Codable, Equatable, Sendable {
    let automatic: String
    let preference: String?
    let accounts: [ClaudeRouterAccount]

    func validate() throws {
        let ids = Set(accounts.map(\.id))
        guard ids.count == accounts.count, ids.contains(automatic), preference.map(ids.contains) ?? true,
              accounts.allSatisfy({ account in
                  account.windows.allSatisfy { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
              }) else { throw AccountServiceError.invalidResponse }
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
    private(set) var accounts: [ClaudeRouterAccount] = []
    private(set) var automatic: String?
    private(set) var preference: String?

    mutating func accept(_ response: ClaudeRouterAccountList) throws {
        try response.validate()
        accounts = response.accounts
        automatic = response.automatic
        preference = response.preference
    }
}

struct ClaudeAccountPreference: Encodable, Sendable {
    let account: String?

    private enum CodingKeys: String, CodingKey { case account }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let account { try values.encode(account, forKey: .account) }
        else { try values.encodeNil(forKey: .account) }
    }
}
