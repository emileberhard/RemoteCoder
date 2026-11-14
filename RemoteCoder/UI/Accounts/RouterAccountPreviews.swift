#if DEBUG
import SwiftUI

@MainActor
private enum RouterAccountFixture {
    static let now = Date.now.timeIntervalSince1970
    enum AutomaticState { case split, unified, exhausted }

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

    static func automaticDirectory(_ state: AutomaticState) -> RouterAccountDirectory {
        let directory = RouterAccountDirectory(storage: HostStorage(root: .temporaryDirectory.appending(path: "router-automatic-preview")),
            beginBackgroundExecution: { _ in {} }, routes: { _ in nil })
        let accounts = [
            automaticAccount(id: "emileberhard388", fiveHour: nil, weekly: 68, fable: state == .unified ? 25 : 100),
            automaticAccount(id: "tent62-latch", fiveHour: 100, weekly: 15, fable: state == .exhausted ? 100 : 25),
            automaticAccount(id: "eberhard-emil", fiveHour: nil, weekly: 96, fable: state == .exhausted ? 100 : 81),
        ]
        let choice: ClaudeModelAutomaticChoice
        switch state {
        case .split: choice = .init(model: "fable", automatic: "eberhard-emil", availableAt: nil)
        case .unified: choice = .init(model: "fable", automatic: "emileberhard388", availableAt: nil)
        case .exhausted:
            guard let date = Calendar.autoupdatingCurrent.date(bySettingHour: 16, minute: 10, second: 0,
                of: Date(timeIntervalSince1970: now)) else { preconditionFailure("Invalid preview return time") }
            choice = .init(model: "fable", automatic: nil, availableAt: date.timeIntervalSince1970)
        }
        do {
            try directory.showPreview(ClaudeRouterAccountList(automatic: "emileberhard388", preference: nil,
                accounts: accounts, models: [choice],
                route: .subscription))
        } catch { preconditionFailure("Invalid automatic account preview: \(error)") }
        return directory
    }

    private static func automaticAccount(id: String, fiveHour: Double?, weekly: Double, fable: Double) -> ClaudeRouterAccount {
        let windows = [
            fiveHour.map { AccountUsageWindow(id: "five-hour", label: "Five hours", durationMinutes: 300,
                usedPercent: $0, resetsAt: now + 10_800, model: nil) },
            AccountUsageWindow(id: "weekly", label: "Weekly", durationMinutes: 10_080,
                usedPercent: weekly, resetsAt: now + 3 * 86_400, model: nil),
            AccountUsageWindow(id: "fable-weekly", label: "\(ClaudeModelCatalog.familyDisplayName(for: "fable")) weekly", durationMinutes: 10_080,
                usedPercent: fable, resetsAt: now + 3 * 86_400, model: "fable", observedAt: now),
        ].compactMap { $0 }
        return ClaudeRouterAccount(id: id, label: id, plan: "max", shared: id == "eberhard-emil", credential: .ready,
            availability: fiveHour == 100 ? .exhausted : .available,
            availableAt: fiveHour == 100 ? now + 10_800 : nil, windows: windows, observedAt: now)
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

private struct CodexPopoverFixture: View {
    let directory: RouterAccountDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GitHub Copilot", systemImage: "person.2").scaledFont(.headline)
            CodexRoutePicker(router: directory).padding(.vertical, 4)
            UsageDetailsContent(rows: directory.copilot?.usageRows(now: .now) ?? [], notice: directory.copilot?.notice, isLoading: false)
        }
        .padding([.horizontal, .bottom], 16)
        .padding(.top, 6)
        .frame(width: 280)
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

private struct PreviewFrame<Content: View>: View {
    @State private var theme = AppThemeStore()
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ThemedAppBackground() }
            .environment(theme)
    }
}

#Preview("Claude on Copilot") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.directory(route: .copilot), providerReason: nil, onShowAllAccounts: {})
    }
}

#Preview("Claude on a subscription") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.directory(route: .subscription), providerReason: nil, onShowAllAccounts: {})
    }
}

#Preview("Accounts") {
    PreviewFrame {
        RouterAccountsFixture(directory: RouterAccountFixture.directory(route: .copilot, codexRoute: .copilot))
    }
}

#Preview("Codex on Copilot") {
    PreviewFrame {
        CodexPopoverFixture(directory: RouterAccountFixture.directory(route: .subscription, codexRoute: .copilot))
    }
}

#Preview("Usage rings") {
    PreviewFrame {
        UsageRingsFixture(directory: RouterAccountFixture.directory(route: .copilot))
    }
}

#Preview("Automatic · Light") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.split), providerReason: nil, onShowAllAccounts: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Automatic · Dark") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.split), providerReason: nil, onShowAllAccounts: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Automatic · Accessibility") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.split), providerReason: nil, onShowAllAccounts: {})
    }
    .dynamicTypeSize(.accessibility1)
}

#Preview("Automatic unified · Light") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.unified), providerReason: nil, onShowAllAccounts: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Automatic unified · Dark") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.unified), providerReason: nil, onShowAllAccounts: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Fable exhausted · Light") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.exhausted), providerReason: nil, onShowAllAccounts: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Fable exhausted · Dark") {
    PreviewFrame {
        ClaudeUsageDetailsView(directory: RouterAccountFixture.automaticDirectory(.exhausted), providerReason: nil, onShowAllAccounts: {})
    }
    .preferredColorScheme(.dark)
}

#endif
