import Foundation
import Testing
@testable import RemoteCoderCore

struct ClaudeRouterAccountTests {
    @Test func latestWholeResponseReplacesOldUsageCredentialsAndMembership() throws {
        var state = ClaudeRouterAccountState()
        try state.accept(list(selected: "one", observed: 200, used: 70))
        let restarted = ClaudeRouterAccountList(automatic: "two", preference: nil, accounts: [
            ClaudeRouterAccount(id: "two", label: "two@example.com", plan: "max", shared: true,
                credential: .rejected, availability: .unavailable, availableAt: nil, windows: [], observedAt: nil)
        ])
        try state.accept(restarted)
        #expect(state.accounts.map(\.id) == ["two"])
        #expect(state.automatic == "two")
        #expect(state.preference == nil)
        #expect(state.accounts.first?.credential == .rejected)
        #expect(state.accounts.first?.observedAt == nil)
        #expect(state.accounts.first?.windows.isEmpty == true)
        let invalid = ClaudeRouterAccountList(automatic: "unknown", preference: nil, accounts: state.accounts)
        #expect(throws: AccountServiceError.self) { try state.accept(invalid) }
        #expect(state.accounts == restarted.accounts)
        #expect(state.automatic == "two")
    }

    @Test func absentUsageStaysUnknownAndShortWarningDependsOnPace() throws {
        let unknown = account(id: "one", observed: nil, windows: [])
        #expect(unknown.usageRows(now: Date(timeIntervalSince1970: 10000)).isEmpty)
        #expect(unknown.menuTitle(now: .distantPast) == "one@example.com · 5h — · Week —")
        let windows = [AccountUsageWindow(id: "five-hour", label: "Five hours", durationMinutes: 300,
            usedPercent: 80, resetsAt: 18000, model: nil),
            AccountUsageWindow(id: "weekly", label: "Weekly", durationMinutes: 10080,
                usedPercent: 35, resetsAt: 604800, model: nil)]
        let sample = account(id: "one", observed: 9000, windows: windows)
        let rows = sample.usageRows(now: Date(timeIntervalSince1970: 9000))
        #expect(rows.first { $0.kind == .weekly }?.remainingPercent == 65)
        #expect(rows.first { $0.kind == .fiveHour }?.runOutWarning != nil)
        #expect(sample.usageRows(now: Date(timeIntervalSince1970: 9901)).allSatisfy { $0.isStale })
        #expect(sample.usageRows(now: Date(timeIntervalSince1970: 9900)).allSatisfy { !$0.isStale })
    }

    @Test func inventoryDecodesRouterPolicyAndStrictStates() throws {
        let data = Data(#"""
        {"automatic":"one","preference":null,"accounts":[{"id":"one","label":"one@example.com","plan":"max","shared":true,"credential":"rejected","availability":"cooling","availableAt":18000,"windows":[],"observedAt":null}]}
        """#.utf8)
        let response = try JSONDecoder().decode(ClaudeRouterAccountList.self, from: data)
        try response.validate()
        #expect(response.automatic == "one")
        #expect(response.preference == nil)
        #expect(response.accounts.first?.plan == "max")
        #expect(response.accounts.first?.shared == true)
        #expect(response.accounts.first?.credential == .rejected)
        #expect(response.accounts.first?.availability == .cooling)
        #expect(response.accounts.first?.availableAt == 18000)
        let invalid = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "rejected", with: "expired").utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClaudeRouterAccountList.self, from: invalid) }
    }

    @Test(arguments: [nil, "one"] as [String?])
    func preferenceRequestPreservesAutomaticAsExplicitNull(_ account: String?) throws {
        let data = try JSONEncoder().encode(ClaudeAccountPreference(account: account))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json == .object(["account": account.map(JSONValue.string) ?? .null]))
    }

    private func list(selected: String, observed: Double, used: Double) -> ClaudeRouterAccountList {
        ClaudeRouterAccountList(automatic: selected, preference: selected, accounts: ["one", "two"].map { id in
            account(id: id, observed: observed,
                windows: [.init(id: "weekly", label: "Weekly", durationMinutes: 10080,
                    usedPercent: used, resetsAt: 604800, model: nil)])
        })
    }

    private func account(id: String, observed: Double?, windows: [AccountUsageWindow]) -> ClaudeRouterAccount {
        ClaudeRouterAccount(id: id, label: "\(id)@example.com", plan: "max", shared: false,
            credential: .ready, availability: .available, availableAt: nil, windows: windows, observedAt: observed)
    }
}
