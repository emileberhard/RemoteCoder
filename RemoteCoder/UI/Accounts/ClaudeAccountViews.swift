import SwiftUI

struct ClaudeUsageRingButton: View {
    var workspace: ChatWorkspaceModel
    let diameter: CGFloat
    @State private var presentation: Presentation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Presentation { case usage, leavingUsageForAccounts, accounts }
    private var directory: ClaudeAccountDirectory { workspace.accountDirectory.claude }

    var body: some View {
        let selected = directory.effectiveAccount
        let rows = selected?.usageRows(now: .now) ?? []
        Button(action: showUsage) {
            UsageRings(provider: .claude, rows: rows, diameter: diameter)
                .padding(4)
                .contentShape(.circle)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.96, pressedOpacity: 0.9))
        .tooltip("Show Claude usage")
        .accessibilityLabel("Claude usage, \(selected?.label ?? "no account selected")")
        .accessibilityValue(rows.isEmpty ? "Unavailable" : rows.map(\.ringAccessibilityValue).joined(separator: ". "))
        .accessibilityIdentifier("usage-claude")
        .contextMenuPreviewShape(Circle())
        .contextMenu {
            Button("Show usage", systemImage: "chart.donut", action: showUsage)
            Button("Refresh usage", systemImage: "arrow.clockwise") {
                Task { await directory.refresh(interactive: true) }
            }
        } preview: {
            ClaudeUsageDetailsView(directory: directory, onShowAllAccounts: {})
        }
        .popover(isPresented: binding(.usage), arrowEdge: .top) {
            ClaudeUsageDetailsView(directory: directory) { presentation = .leavingUsageForAccounts }
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
    var directory: ClaudeAccountDirectory
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

    private var selection: Binding<String?> {
        Binding(get: { directory.state.preference }, set: { id in
            Task { await directory.setPreference(id) }
        })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppMenu(trigger: .icon) {
                Picker("Account", selection: selection.nativeSelectionFeedback()) {
                    Text("Automatic").tag(nil as String?)
                    ForEach(directory.accounts) { account in
                        Text(menuTitle(account)).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!directory.canSelect)
                Section { Button("All Accounts", systemImage: "person.2", action: onShowAllAccounts) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: AgentProvider.claude.symbolName)
                        .resizable().scaledToFit().foregroundStyle(.secondary)
                        .frame(width: markSize, height: markSize)
                    Text(directory.state.preference == nil ? "Automatic" : directory.effectiveAccount?.label ?? "Choose Account")
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
            .accessibilityValue(directory.effectiveAccount?.label ?? "None selected")
            if let error = directory.error {
                Text(error).scaledFont(.footnote).foregroundStyle(.secondary)
            }
            UsageDetailsContent(rows: directory.effectiveAccount?.usageRows(now: .now) ?? [],
                                notice: directory.effectiveAccount?.notice, isLoading: directory.isRefreshing)
            AccountResetCount(resets: directory.effectiveAccount?.resets, isStale: directory.effectiveAccount?.resets?.isStale(now: .now) != false)
        }
        .padding([.horizontal, .bottom], 16)
        .padding(.top, 6)
    }
}

struct ClaudeAccountSummaryRow: View {
    var directory: ClaudeAccountDirectory
    let account: ClaudeRouterAccount
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    HapticService.shared.play(.selection)
                    Task { await directory.setPreference(account.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: account.id == directory.state.preference ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(account.id == directory.state.preference ? Color.accentColor : .secondary)
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
                .accessibilityValue(account.id == directory.state.preference ? "Selected" : "Not selected")
                .accessibilityIdentifier("select-claude-account-\(account.id)")
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Usage details for \(account.label)")
                .tooltip("Show usage details")
            }
            Text([account.plan.capitalized, account.shared ? "Shared" : nil, account.availabilityText].compactMap { $0 }.joined(separator: " · "))
                .scaledFont(.caption).foregroundStyle(.secondary).padding(.leading, 32)
            UsageDetailsContent(rows: account.usageRows(now: .now), notice: account.notice, isLoading: directory.isRefreshing)
                .padding(.leading, 32)
            AccountResetCount(resets: account.resets, isStale: account.resets?.isStale(now: .now) != false).padding(.leading, 32)
        }
        .padding(.vertical, 6)
    }
}

struct ClaudeAccountDetailView: View {
    var directory: ClaudeAccountDirectory
    let accountID: String

    var body: some View {
        List {
            if let account = directory.accounts.first(where: { $0.id == accountID }) {
                Section {
                    Text(account.label).scaledFont(.headline).textSelection(.enabled)
                    Text([account.plan.capitalized, account.shared ? "Shared" : nil, account.availabilityText]
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
