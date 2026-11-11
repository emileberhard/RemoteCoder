import SwiftUI

struct ClaudeUsageRingButton: View {
    var workspace: ChatWorkspaceModel
    let diameter: CGFloat
    @State private var presentation: Presentation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Presentation { case usage, leavingUsageForAccounts, accounts }
    private var directory: RouterAccountDirectory { workspace.accountDirectory.router }

    var body: some View {
        let selected = directory.effectiveAccount
        let copilot = directory.state.choice == .copilot ? directory.copilot : nil
        let rows = copilot?.usageRows(now: .now) ?? selected?.usageRows(now: .now) ?? []
        let status = workspace.providerStatus(of: .claude)
        Button(action: showUsage) {
            UsageRings(mark: copilot == nil ? .provider(.claude) : .copilot, rows: rows, status: status, diameter: diameter)
                .padding(4)
                .contentShape(.circle)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.96, pressedOpacity: 0.9))
        .tooltip("Show Claude usage")
        .accessibilityLabel("Claude usage, \(copilot == nil ? selected?.label ?? "no account selected" : "GitHub Copilot")")
        .accessibilityValue(UsageRings.accessibilityValue(rows: rows, status: status))
        .accessibilityIdentifier("usage-claude")
        .contextMenuPreviewShape(Circle())
        .contextMenu {
            Button("Show usage", systemImage: "chart.donut", action: showUsage)
            Button("Refresh usage", systemImage: "arrow.clockwise") {
                Task { await directory.refresh(interactive: true) }
            }
        } preview: {
            ClaudeUsageDetailsView(directory: directory, providerReason: status?.reason, onShowAllAccounts: {})
        }
        .popover(isPresented: binding(.usage), arrowEdge: .top) {
            ClaudeUsageDetailsView(directory: directory, providerReason: status?.reason) {
                presentation = .leavingUsageForAccounts
            }
                .task { await directory.refresh(interactive: true) }
                .onDisappear {
                    if presentation == .leavingUsageForAccounts { presentation = .accounts }
                }
                .presentationCompactAdaptation(horizontal: dynamicTypeSize.isAccessibilitySize ? .sheet : .popover, vertical: .sheet)
                .presentationDetents([.large])
                .presentationSizing(.fitted)
        }
        .accountsOverviewPresentation(isPresented: binding(.accounts), workspace: workspace)
    }

    private func showUsage() { presentation = .usage }

    private func binding(_ target: Presentation) -> Binding<Bool> {
        Binding(get: { presentation == target }, set: { if !$0, presentation == target { presentation = nil } })
    }
}

struct ClaudeUsageDetailsView: View {
    var directory: RouterAccountDirectory
    let providerReason: String?
    let onShowAllAccounts: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @InterfaceScaledMetric(relativeTo: .headline) private var markSize = 18

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.frame(maxHeight: 620)
        }
        .frame(idealWidth: dynamicTypeSize.isAccessibilitySize ? nil : 280,
               maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 280)
    }

    private func menuTitle(_ account: ClaudeRouterAccount) -> String {
        account.menuTitle(now: .now) + (account.id == directory.state.automatic ? " · Automatic" : "")
    }

    private var selection: Binding<ClaudeChoice?> {
        Binding(get: { directory.state.choice }, set: { choice in
            guard let choice else { return }
            Task { await directory.select(.claude(choice)) }
        })
    }

    private var title: String {
        switch directory.state.choice {
        case .automatic?, nil: "Automatic"
        case .account?: directory.effectiveAccount?.label ?? "Choose Account"
        case .copilot?: "GitHub Copilot"
        case .openrouter?: "OpenRouter"
        }
    }

    private var copilot: CopilotRouterAccount? { directory.state.choice == .copilot ? directory.copilot : nil }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppMenu(trigger: .icon) {
                Picker("Account", selection: selection.nativeSelectionFeedback()) {
                    Text("Automatic").tag(ClaudeChoice?.some(.automatic))
                    ForEach(directory.accounts) { account in
                        Text(menuTitle(account)).tag(ClaudeChoice?.some(.account(account.id)))
                    }
                    if let copilot = directory.copilot, directory.state.offers(.claude(.copilot)) {
                        Label(copilot.menuTitle, image: "CopilotMark").tag(ClaudeChoice?.some(.copilot))
                    }
                    if directory.state.choice == .openrouter {
                        Text("OpenRouter").tag(ClaudeChoice?.some(.openrouter))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!directory.canSelect)
                Section { Button("All Accounts", systemImage: "person.2", action: onShowAllAccounts) }
            } label: {
                HStack(spacing: 8) {
                    let mark: UsageMark = copilot == nil ? .provider(.claude) : .copilot
                    Image(mark.image)
                        .resizable().scaledToFit().foregroundStyle(mark.style)
                        .frame(width: markSize, height: markSize)
                    Text(title)
                        .scaledFont(.headline).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ControlMetrics.minimumTarget)
                .contentShape(.rect)
            }
            .accessibilityLabel("Claude account")
            .accessibilityValue(directory.state.choice == nil ? "None selected" : title)
            if let providerReason {
                ProviderWarningLabel(text: providerReason).scaledFont(.footnote)
            }
            if let error = directory.error {
                Text(error).scaledFont(.footnote).foregroundStyle(.secondary)
            }
            if let copilot {
                UsageDetailsContent(rows: copilot.usageRows(now: .now), notice: copilot.notice, isLoading: directory.isRefreshing)
            } else {
                UsageDetailsContent(rows: directory.effectiveAccount?.usageRows(now: .now) ?? [],
                                    notice: directory.effectiveAccount?.notice, isLoading: directory.isRefreshing)
                AccountResetCount(resets: directory.effectiveAccount?.resets, isStale: directory.effectiveAccount?.resets?.isStale(now: .now) != false)
            }
        }
        .padding([.horizontal, .bottom], 16)
        .padding(.top, 6)
    }
}

struct ClaudeAccountSummaryRow: View {
    var directory: RouterAccountDirectory
    let account: ClaudeRouterAccount
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    HapticService.shared.play(.selection)
                    Task { await directory.select(.claude(.account(account.id))) }
                } label: {
                    HStack(spacing: 10) {
                        RadioMark(isSelected: isSelected)
                        Text(account.label).scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        if account.id == directory.state.automatic {
                            Text("Automatic").scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: ControlMetrics.minimumTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!directory.canSelect)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityIdentifier("select-claude-account-\(account.id)")
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Usage details for \(account.label)")
                .tooltip("Show usage details")
            }
            Text([account.planTitle, account.shared ? "Shared" : nil, account.availabilityText].compactMap { $0 }.joined(separator: " · "))
                .scaledFont(.caption).foregroundStyle(.secondary).padding(.leading, 32)
            UsageDetailsContent(rows: account.usageRows(now: .now), notice: account.notice, isLoading: directory.isRefreshing)
                .padding(.leading, 32)
            AccountResetCount(resets: account.resets, isStale: account.resets?.isStale(now: .now) != false).padding(.leading, 32)
        }
        .padding(.vertical, 6)
    }

    private var isSelected: Bool { directory.state.choice == .account(account.id) }
}

struct CopilotAccountSummaryRow: View {
    var directory: RouterAccountDirectory
    let account: CopilotRouterAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                HapticService.shared.play(.selection)
                Task { await directory.select(.claude(.copilot)) }
            } label: {
                HStack(spacing: 10) {
                    RadioMark(isSelected: isSelected)
                    Image("CopilotMark").resizable().scaledToFit().scaledFrame(width: 16, height: 16)
                    Text("GitHub Copilot").scaledFont(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ControlMetrics.minimumTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!directory.canSelect)
            .accessibilityLabel("GitHub Copilot, \(account.label)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityIdentifier("select-claude-copilot")
            Text([account.label, account.plan.capitalized, account.availabilityText].joined(separator: " · "))
                .scaledFont(.caption).foregroundStyle(.secondary).padding(.leading, 32)
            UsageDetailsContent(rows: account.usageRows(now: .now), notice: account.notice, isLoading: directory.isRefreshing)
                .padding(.leading, 32)
        }
        .padding(.vertical, 6)
    }

    private var isSelected: Bool { directory.state.choice == .copilot }
}

private struct RadioMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
    }
}

struct ClaudeAccountDetailView: View {
    var directory: RouterAccountDirectory
    let accountID: String

    var body: some View {
        List {
            if let account = directory.accounts.first(where: { $0.id == accountID }) {
                Section {
                    Text(account.label).scaledFont(.headline).textSelection(.enabled)
                    Text([account.planTitle, account.shared ? "Shared" : nil, account.availabilityText]
                        .compactMap { $0 }.joined(separator: " · "))
                        .scaledFont(.subheadline).foregroundStyle(.secondary)
                }
                Section("Allowance remaining") {
                    UsageDetailsContent(rows: account.usageRows(now: .now), notice: account.notice, isLoading: directory.isRefreshing)
                }
                Section("Usage resets") {
                    AccountResetOffersView(resets: account.resets, accountName: account.label,
                        redemption: directory.resetRedemptions.states[account.id],
                        isEnabled: directory.resetRedemptions.isRestored,
                        isStale: account.resets?.isStale(now: .now) != false,
                        error: directory.resetRedemptions.error,
                        onUse: { offer in Task { await directory.redeemReset(accountID: account.id, offer: offer) } },
                        onRetry: { Task { await directory.retryReset(accountID: account.id) } },
                        onForget: { Task { await directory.resetRedemptions.forget(accountID: account.id) } })
                }
            } else {
                ContentUnavailableView("Account unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                if let state = directory.resetRedemptions.states[accountID], let attempt = state.attempt {
                    AccountResetAttemptView(accountName: attempt.accountName, redemption: state,
                        isEnabled: directory.resetRedemptions.isRestored,
                        onRetry: { Task { await directory.retryReset(accountID: accountID) } },
                        onForget: { Task { await directory.resetRedemptions.forget(accountID: accountID) } })
                }
            }
        }
        .navigationTitle("Account details")
        .inlineNavigationTitle()
        .refreshable { await directory.refresh(interactive: true) }
        .task { await directory.refresh(interactive: true) }
    }
}
