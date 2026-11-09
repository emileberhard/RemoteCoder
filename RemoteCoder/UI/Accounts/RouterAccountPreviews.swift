#if DEBUG
import SwiftUI

private enum RouterAccountFixture {
    static let now = Date.now.timeIntervalSince1970

    static func list(route: ClaudeRoute, codexRoute: CodexRoute) -> ClaudeRouterAccountList {
        ClaudeRouterAccountList(automatic: "max", preference: route == .subscription ? "max" : nil, accounts: [
            account(id: "max", label: "max@example.com", fiveHour: 38, weekly: 61),
            account(id: "pro", label: "pro@example.com", fiveHour: 4, weekly: 22),
        ], route: route, codexRoute: codexRoute, copilot: CopilotRouterAccount(
            label: "octocat", plan: "business", availability: .available, availableAt: nil, error: nil,
            budget: .init(limitUsd: 150, spentUsd: 41.2, remainingUsd: 108.8, resetsAt: now + 21 * 86_400)))
    }

    static func directory(route: ClaudeRoute, codexRoute: CodexRoute = .subscription) -> RouterAccountDirectory {
        let directory = RouterAccountDirectory(storage: HostStorage(root: .temporaryDirectory.appending(path: "router-account-preview")),
            beginBackgroundExecution: { _ in {} }, routes: { _ in nil })
        try! directory.showPreview(list(route: route, codexRoute: codexRoute))
        return directory
    }

    private static func account(id: String, label: String, fiveHour: Double, weekly: Double) -> ClaudeRouterAccount {
        ClaudeRouterAccount(id: id, label: label, plan: "max", shared: false, credential: .ready, availability: .available,
            availableAt: nil, windows: [
                AccountUsageWindow(id: "five_hour", label: "5-hour", durationMinutes: 300, usedPercent: fiveHour,
                    resetsAt: now + 7_200, model: nil),
                AccountUsageWindow(id: "weekly", label: "Weekly", durationMinutes: 10_080, usedPercent: weekly,
                    resetsAt: now + 3 * 86_400, model: nil),
            ], observedAt: now)
    }
}

private struct RouterAccountsFixture: View {
    let directory: RouterAccountDirectory

    var body: some View {
        List {
            Section("Claude") {
                Label("Automatic", systemImage: directory.state.choice == .automatic ? "checkmark.circle.fill" : "circle")
                ForEach(directory.accounts) { account in
                    ClaudeAccountSummaryRow(directory: directory, account: account, onDetails: {})
                }
                if let copilot = directory.copilot {
                    CopilotAccountSummaryRow(directory: directory, account: copilot)
                }
            }
            Section("Codex") {
                CodexRoutePicker(router: directory)
            }
        }
    }
}

private struct UsageRingsFixture: View {
    let directory: RouterAccountDirectory

    var body: some View {
        HStack(spacing: 0) {
            UsageRings(mark: .provider(.claude), rows: directory.accounts[0].usageRows(now: .now), status: nil, diameter: 36)
                .padding(4)
            UsageRings(mark: .copilot, rows: directory.copilot?.usageRows(now: .now) ?? [], status: nil, diameter: 36)
                .padding(4)
        }
        .appGlass(.standard, in: .capsule, interactive: true)
        .padding()
    }
}

#Preview("Claude on Copilot") {
    ClaudeUsageDetailsView(directory: RouterAccountFixture.directory(route: .copilot), providerReason: nil, onShowAllAccounts: {})
}

#Preview("Claude on a subscription") {
    ClaudeUsageDetailsView(directory: RouterAccountFixture.directory(route: .subscription), providerReason: nil, onShowAllAccounts: {})
}

#Preview("Accounts") {
    RouterAccountsFixture(directory: RouterAccountFixture.directory(route: .copilot, codexRoute: .copilot))
}

#Preview("Usage rings") {
    UsageRingsFixture(directory: RouterAccountFixture.directory(route: .copilot))
}
#endif
