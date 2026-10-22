import SwiftUI

/// All subscriptions share one overview; physical hosts remain separate execution choices.
struct AccountsOverviewView: View {
    @Bindable var workspace: ChatWorkspaceModel
    @State private var detailAccountID: String?
    @State private var detailClaudeAccountID: String?
    @State private var renaming: Rename?
    @State private var nameDraft = ""
    private var names: AccountNameStore { workspace.accountDirectory.names }

    private struct Rename: Identifiable {
        let provider: AgentProvider
        let identity: ProviderAccountIdentity
        var id: String { provider.groupID(for: identity) }
    }

    var body: some View {
        List {
            if !workspace.accountDirectory.claude.accounts.isEmpty {
                Section("Claude") {
                    Button {
                        HapticService.shared.play(.selection)
                        Task { await workspace.accountDirectory.claude.setPreference(nil) }
                    } label: {
                        Label("Automatic", systemImage: workspace.accountDirectory.claude.state.preference == nil ? "checkmark.circle.fill" : "circle")
                    }
                    .disabled(!workspace.accountDirectory.claude.canSelect)
                    ForEach(workspace.accountDirectory.claude.accounts) { account in
                        ClaudeAccountSummaryRow(directory: workspace.accountDirectory.claude, account: account,
                                                onDetails: { detailClaudeAccountID = account.id })
                    }
                }
            }
            if let error = workspace.accountDirectory.claude.error {
                Section { Text(error).scaledFont(.footnote).foregroundStyle(.secondary) }
            }
            ForEach([AgentProvider.codex].filter { provider in
                workspace.accountDirectory.groups.contains { $0.provider == provider }
            }, id: \.self) { provider in
                Section {
                    ForEach(workspace.accountDirectory.groups.filter { $0.provider == provider }) { group in
                        AccountSummaryRow(
                            group: group,
                            onDetails: { detailAccountID = group.id }
                        )
                        .contextMenu {
                            if group.provider == .codex, let identity = group.sample.identity {
                                Button("Rename", systemImage: "pencil") {
                                    nameDraft = names.nickname(provider: group.provider, identity: identity) ?? ""
                                    renaming = Rename(provider: group.provider, identity: identity)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                        if provider == .codex { Text("Remaining").textCase(nil) }
                    }
                }
            }
            OrphanedAccountResetsView(redemptions: workspace.accountDirectory.resetRedemptions,
                accountIDs: Set(workspace.accountDirectory.groups.map(\.id)),
                onRetry: { id in Task { await workspace.accountDirectory.retryReset(groupID: id) } })
            OrphanedAccountResetsView(redemptions: workspace.accountDirectory.claude.resetRedemptions,
                accountIDs: Set(workspace.accountDirectory.claude.accounts.map(\.id)),
                onRetry: { id in Task { await workspace.accountDirectory.claude.retryReset(accountID: id) } })
            if workspace.accountDirectory.groups.filter({ $0.provider == .codex }).isEmpty, workspace.accountDirectory.claude.accounts.isEmpty {
                Section {
                    if workspace.accountDirectory.hosts.contains(where: \.isRefreshing) {
                        ProgressView("Loading accounts…")
                    } else {
                        ContentUnavailableView("No accounts", systemImage: "person.crop.circle",
                                               description: Text("Accounts are managed in llm-router."))
                    }
                }
            }
            if workspace.accountDirectory.hosts.contains(where: { $0.error != nil }) {
                Section {
                    #if os(macOS)
                    HStack {
                        Label("Some accounts couldn't be updated.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await workspace.accountDirectory.refresh(interactive: true) } }
                    }
                    #else
                    Label("Some accounts couldn't be updated. Pull to refresh.", systemImage: "exclamationmark.triangle")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                    #endif
                }
            }
        }
        .navigationTitle("Accounts & usage")
        .inlineNavigationTitle()
        .refreshable { await workspace.accountDirectory.refresh(interactive: true) }
        .task { await workspace.accountDirectory.refresh(interactive: true) }
        .navigationDestination(item: $detailAccountID) { id in
            AccountUsageDetailView(workspace: workspace, accountID: id)
        }
        .navigationDestination(item: $detailClaudeAccountID) { id in
            ClaudeAccountDetailView(directory: workspace.accountDirectory.claude, accountID: id)
        }
        .alert("Rename account", item: $renaming) { target in
            TextField(names.defaultName(provider: target.provider, identity: target.identity), text: $nameDraft)
            Button("Save") {
                names.rename(provider: target.provider, identity: target.identity, to: nameDraft)
                HapticService.shared.play(.commit)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Leave empty to show \(names.defaultName(provider: target.provider, identity: target.identity)).")
        }
    }
}

struct AccountSummaryRow: View {
    let group: AccountDirectory.AccountGroup
    let onDetails: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onDetails) { title }
                .buttonStyle(.plain)
            if group.provider == .codex {
                usage
            } else if let reason = group.sample.notReadyReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var usage: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 10) {
            ForEach([UsageWindowKind.fiveHour, .weekly], id: \.self) { kind in
                let row = group.sample.usageRows.first { $0.kind == kind }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label).scaledFont(.caption).foregroundStyle(.secondary)
                    Text(row.map { "\($0.remainingPercent)%" } ?? "—")
                        .scaledFont(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(row?.remainingColor ?? .secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(kind.label)
                .accessibilityValue(row.map { "\($0.remainingPercent) percent remaining\($0.isStale ? ", last known" : "")" } ?? "Not reported")
            }
        }
        if let notice = group.sample.usageNotice {
            Text(notice)
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
        AccountResetCount(resets: group.sample.resets, isStale: group.sample.stale)
    }

    private var title: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let plan = group.sample.plan {
                    Text(plan.capitalized)
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
        .contentShape(.rect)
    }
}

struct AccountUsageDetailView: View {
    @Bindable var workspace: ChatWorkspaceModel
    let accountID: String

    var body: some View {
        List {
            if let group = workspace.accountDirectory.groups.first(where: { $0.id == accountID }) {
                Section {
                    Text(group.title).scaledFont(.headline).textSelection(.enabled)
                    Text(group.sample.usageStatus).scaledFont(.subheadline).foregroundStyle(.secondary)
                }
                Section("Allowance remaining") {
                    UsageDetailsContent(rows: group.sample.usageRows, notice: nil, isLoading: false)
                }
                Section("Usage resets") {
                    AccountResetOffersView(resets: group.sample.resets, accountName: group.title,
                        redemption: workspace.accountDirectory.resetRedemptions.states[group.id],
                        isEnabled: workspace.accountDirectory.resetRedemptions.isRestored,
                        isStale: group.sample.stale,
                        error: workspace.accountDirectory.resetRedemptions.error,
                        onUse: { offer in Task { await workspace.accountDirectory.redeemReset(groupID: group.id, offer: offer) } },
                        onRetry: { Task { await workspace.accountDirectory.retryReset(groupID: group.id) } },
                        onForget: { Task { await workspace.accountDirectory.resetRedemptions.forget(accountID: group.id) } })
                }
            } else {
                ContentUnavailableView("Account unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                if let state = workspace.accountDirectory.resetRedemptions.states[accountID], let attempt = state.attempt {
                    AccountResetAttemptView(accountName: attempt.accountName, redemption: state,
                        isEnabled: workspace.accountDirectory.resetRedemptions.isRestored,
                        onRetry: { Task { await workspace.accountDirectory.retryReset(groupID: accountID) } },
                        onForget: { Task { await workspace.accountDirectory.resetRedemptions.forget(accountID: accountID) } })
                }
            }
        }
        .navigationTitle("Account details")
        .inlineNavigationTitle()
        .refreshable { await workspace.accountDirectory.refreshCodex(interactive: true) }
    }
}
