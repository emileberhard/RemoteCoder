#if os(macOS)
import AppKit
import SwiftUI

struct ConversationHistoryList: View {
    var workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let snapshot: ConversationSidebarSnapshot?
    let notice: DrawerNotice?
    let undo: DrawerUndo?
    let actions: ConversationHistoryActions
    let onUndo: () -> Void
    let onInteractionChanged: (Bool) -> Void

    @State private var selection: Set<ConversationAddress> = []
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = snapshot?.items ?? []
        let sections = ConversationSidebarSections.sections(of: items)
        let hostNames = workspace.hasMultipleHosts
            ? Dictionary(workspace.settings.hosts.map { ($0.id, $0.displayName) }) { first, _ in first }
            : [:]
        let drafts = snapshot?.drafts ?? []
        List(selection: $selection) {
            if !drafts.isEmpty {
                draftsSection(drafts, hiddenCount: snapshot?.hiddenDraftCount ?? 0, hostNames: hostNames)
            }
            ForEach(sections) { section in
                switch section.kind {
                case let .pinned(summary):
                    foldableSection(summary, rows: section.rows, hostNames: hostNames,
                                    setFolded: { workspace.drawerPreferences.isPinnedFolded = $0 }) {
                        Text("Pinned")
                    }
                case let .automations(summary):
                    foldableSection(summary, rows: section.rows, hostNames: hostNames,
                                    setFolded: { workspace.drawerPreferences.isAutomationsFolded = $0 }) {
                        Label("Automations", systemImage: "clock.arrow.circlepath")
                    }
                case let .project(header):
                    foldableSection(header.summary, rows: section.rows, hostNames: hostNames,
                                    setFolded: { workspace.setFolded($0, project: header.key, in: window) }) {
                        projectTitle(header)
                    }
                case .chats:
                    Section("Chats") { rows(section.rows, hostNames: hostNames) }
                case let .settled(summary, hiddenRowCount):
                    settledSection(summary, rows: section.rows, hiddenRowCount: hiddenRowCount, hostNames: hostNames)
                case .unsectioned:
                    if drafts.isEmpty {
                        rows(section.rows, hostNames: hostNames)
                    } else {
                        Section("Chats") { rows(section.rows, hostNames: hostNames) }
                    }
                }
            }
            ConversationHistoryLoadingFooter(workspace: workspace, window: window, states: snapshot?.hostStates ?? [], open: actions.open)
                .buttonStyle(.link)
        }
        .listStyle(.sidebar)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .searchable(text: Bindable(window).drawerQuery, placement: .sidebar, prompt: "Filter")
        .contextMenu(forSelectionType: ConversationAddress.self) { addresses in
            if let row = singleRow(in: addresses, of: items) {
                menu(for: row)
            } else if addresses.count > 1 {
                batchMenu(for: addresses, of: items)
            }
        } primaryAction: { addresses in
            if singleRow(in: addresses, of: items) != nil { actions.focusComposer() }
        }
        .onDeleteCommand {
            let chosen = selectedRows(selection, in: items)
            if !chosen.isEmpty, chosen.allSatisfy(\.isSettled) {
                actions.unsettle(chosen.map(\.address))
            } else {
                let settleable = chosen.filter(\.canSettle).map(\.address)
                if !settleable.isEmpty { actions.settle(settleable) }
            }
        }
        .overlay { placeholder(isEmpty: items.isEmpty && drafts.isEmpty) }
        .safeAreaBar(edge: .bottom) { statusBar }
        .task(id: shownConversation) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            selection = shownConversation.map { [$0] } ?? []
        }
        .onChange(of: selection) { _, chosen in
            guard chosen.count == 1, let chosen = chosen.first else { return }
            let shown = shownConversation
            guard chosen != shown else { return }
            let isPointerChoice = NSApp.isHandlingPointerEvent
            guard open(chosen) == .changed, isPointerChoice else { return }
            Task { actions.focusComposer() }
        }
        .onScrollPhaseChange { _, phase in onInteractionChanged(phase != .idle) }
        .onDisappear { onInteractionChanged(false) }
    }

    private var shownConversation: ConversationAddress? {
        for case let .row(row) in snapshot?.items ?? [] where row.isSelected { return row.address }
        return nil
    }

    @ViewBuilder
    private func foldableSection(_ summary: ConversationSectionSummary, rows sectionRows: [ConversationSidebarRow],
                                 hostNames: [UUID: String], setFolded: @escaping (Bool) -> Void,
                                 @ViewBuilder title: () -> some View) -> some View {
        let header = sectionHeader(summary, title: title)
        switch summary.fold {
        case .searching:
            Section {
                rows(sectionRows, hostNames: hostNames)
            } header: {
                header
            }
        case .expanded, .folded:
            Section(isExpanded: Binding(get: { summary.fold == .expanded }, set: { setFolded(!$0) })) {
                rows(sectionRows, hostNames: hostNames)
            } header: {
                header
            }
        }
    }

    @ViewBuilder
    private func settledSection(_ summary: ConversationSectionSummary, rows sectionRows: [ConversationSidebarRow],
                                hiddenRowCount: Int, hostNames: [UUID: String]) -> some View {
        let header = sectionHeader(summary) {
            HStack(spacing: 6) {
                Text("Settled")
                Text(summary.rowCount, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        let isExpanded = Binding(get: { summary.fold == .expanded },
                                 set: { workspace.drawerPreferences.isSettledFolded = !$0 })
        switch summary.fold {
        case .searching:
            Section {
                rows(sectionRows, hostNames: hostNames)
            } header: {
                header
            }
        case .expanded:
            Section(isExpanded: isExpanded) {
                rows(sectionRows, hostNames: hostNames)
                if hiddenRowCount > 0 {
                    Button("Show \(hiddenRowCount) more") { window.revealMoreSettled() }
                        .buttonStyle(.link)
                }
            } header: {
                header
            }
        case .folded:
            Section(isExpanded: isExpanded) {
                EmptyView()
            } header: {
                header
            }
            rows(sectionRows, hostNames: hostNames)
        }
    }

    private func sectionHeader(_ summary: ConversationSectionSummary, @ViewBuilder title: () -> some View) -> some View {
        HStack(spacing: 6) {
            title()
            Spacer(minLength: 0)
            if summary.fold == .folded {
                if let liveActivity = summary.liveActivity, let symbol = ConversationRowStatus.symbol(for: liveActivity) {
                    Image(systemName: symbol.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(symbol.style)
                        .help(symbol.label)
                        .accessibilityLabel(symbol.label)
                }
                if summary.unreadCount > 0 {
                    Circle()
                        .fill(.tint)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("\(summary.unreadCount) unread")
                }
            }
        }
    }

    private func projectTitle(_ header: ConversationProjectHeader) -> some View {
        HStack(spacing: 6) {
            Text(header.title)
                .lineLimit(1)
                .truncationMode(.head)
            if let hostName = header.hostName {
                Text(hostName)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func rows(_ rows: [ConversationSidebarRow], hostNames: [UUID: String]) -> some View {
        ForEach(rows) { row in
            ConversationSourceRow(row: row, hostName: hostNames[row.address.hostID]) { actions.settle([row.address]) }
                .equatable()
                .contentTransition(.identity)
                .tag(row.address)
                .typeSelectEquivalent(row.title)
                .accessibilityIdentifier("conversation-row-\(row.id)")
        }
    }

    private func draftsSection(_ drafts: [UnsentDraftRow], hiddenCount: Int, hostNames: [UUID: String]) -> some View {
        Section("Drafts") {
            ForEach(drafts) { draft in
                UnsentDraftSourceRow(row: draft, hostName: hostNames[draft.address.target.hostID]) { openDraft(draft.address) }
                    .equatable()
                    .contentTransition(.identity)
                    .accessibilityIdentifier("unsent-draft-\(draft.address.draftID)")
                    .contextMenu {
                        Button("Open Draft", systemImage: "square.and.pencil") { openDraft(draft.address) }
                        Divider()
                        Button("Discard Draft", systemImage: "trash", role: .destructive) { actions.discardDraft(draft.address) }
                    }
            }
            if hiddenCount > 0 {
                Button("Show \(hiddenCount) more") { window.revealAllDrafts() }
                    .buttonStyle(.link)
            }
        }
    }

    private func openDraft(_ address: UnsentDraftAddress) {
        actions.openDraft(address)
        Task { actions.focusComposer() }
    }

    private func singleRow(in addresses: Set<ConversationAddress>, of items: [ConversationSidebarItem]) -> ConversationSidebarRow? {
        guard addresses.count == 1, let address = addresses.first else { return nil }
        for case let .row(row) in items where row.address == address { return row }
        return nil
    }

    private func selectedRows(_ addresses: Set<ConversationAddress>, in items: [ConversationSidebarItem]) -> [ConversationSidebarRow] {
        items.compactMap { item in
            guard case let .row(row) = item, addresses.contains(row.address) else { return nil }
            return row
        }
    }

    @ViewBuilder
    private func menu(for row: ConversationSidebarRow) -> some View {
        Button("Open in New Window") { openWindow(value: ConversationWindowValue.conversation(row.address)) }
        Divider()
        ForEach(actions.rowMenuItems(for: row)) { item in
            Button(item.title, systemImage: item.systemImage, action: item.perform)
        }
    }

    @ViewBuilder
    private func batchMenu(for addresses: Set<ConversationAddress>, of items: [ConversationSidebarItem]) -> some View {
        let chosen = selectedRows(addresses, in: items)
        Button("Mark \(chosen.count) as Read", systemImage: "envelope.open") {
            actions.markRead(chosen.map(\.address))
        }
        if !chosen.isEmpty, chosen.allSatisfy(\.isSettled) {
            Button("Unsettle \(chosen.count) Chats", systemImage: ConversationSettlementSymbol.unsettle) {
                actions.unsettle(chosen.map(\.address))
            }
        } else {
            let settleable = chosen.filter(\.canSettle)
            Button("Settle \(settleable.count) Chats", systemImage: ConversationSettlementSymbol.settle) {
                actions.settle(settleable.map(\.address))
            }
            .disabled(settleable.isEmpty)
        }
    }

    private func open(_ address: ConversationAddress) -> ChatWorkspaceModel.ConversationSwitchOutcome {
        let outcome = actions.open(address)
        if outcome != .changed { selection = shownConversation.map { [$0] } ?? [] }
        return outcome
    }

    @ViewBuilder
    private func placeholder(isEmpty: Bool) -> some View {
        if isEmpty, snapshot?.hostStates.contains(where: \.isLoading) ?? true {
            ProgressView()
                .accessibilityLabel("Loading history")
        } else if isEmpty, snapshot?.hostStates.contains(where: { $0.canLoadMore || $0.hasDiscardedHeaders || !$0.unloadedPins.isEmpty }) == true {
            EmptyView()
        } else if isEmpty, !window.drawerQuery.isEmpty {
            ContentUnavailableView.search(text: window.drawerQuery)
        } else if isEmpty, workspace.drawerPreferences.unreadOnly {
            ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle")
        } else if isEmpty {
            ContentUnavailableView("No Conversations", systemImage: "clock.arrow.circlepath")
        }
    }

    private var statusBar: some View {
        let reporting = snapshot?.hostStates.filter { $0.status != nil } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            if let undo {
                HStack {
                    Text(undo.message)
                    Spacer(minLength: 0)
                    Button("Undo", action: onUndo)
                        .buttonStyle(.borderless)
                }
                .transition(.opacity)
            }
            if let notice {
                Text(notice.message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .transition(.opacity)
            }
            ForEach(reporting) { state in
                HostStatusText(state: state, namingHost: workspace.hasMultipleHosts)
            }
            HStack(spacing: 2) {
                ClaudeUsageRingButton(workspace: workspace, diameter: 20)
                    .help("Show Claude usage")
                UsageRingButton(workspace: workspace, diameter: 20)
                    .help("Show Codex usage")
                Spacer(minLength: 0)
                viewOptions
            }
        }
        .scaledFont(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .default, value: notice)
        .animation(reduceMotion ? nil : .default, value: undo)
    }
}

private extension ConversationHistoryList {
    var viewOptions: some View {
        let preferences = workspace.drawerPreferences
        return AppMenu(trigger: .icon) {
            Picker("Sort", selection: Bindable(preferences).mode) {
                Text("Priority").tag(ConversationDrawerMode.priority)
                Text("Projects").tag(ConversationDrawerMode.projects)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(ChatCommand.unreadOnly.title(in: nil), isOn: Bindable(preferences).unreadOnly)
            Divider()
            Button(ChatCommand.markAllRead.title(in: nil)) { workspace.markAllRead() }
            Button(ChatCommand.collapseAllSections.title(in: nil)) { workspace.setAllSectionsFolded(true, in: window) }
            Button(ChatCommand.expandAllSections.title(in: nil)) { workspace.setAllSectionsFolded(false, in: window) }
        } label: {
            Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View options")
    }
}

private struct ConversationSourceRow: View, Equatable {
    let row: ConversationSidebarRow
    let hostName: String?
    let settle: () -> Void
    @State private var isHovered = false
    @Environment(\.sidebarRowSize) private var rowSize
    @Environment(\.interfaceScale) private var scale
    @Environment(\.backgroundProminence) private var prominence

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.hostName == rhs.hostName }

    var body: some View {
        let provider = AgentProvider.provider(forThreadID: row.address.threadID)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: dotSpacing) {
                Circle()
                    .fill(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                    .frame(width: dotDiameter, height: dotDiameter)
                    .opacity(row.isUnread ? 1 : 0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .scaledFont(rowSize.titleFont)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isHovered, row.canSettle {
                        Button("Settle", systemImage: ConversationSettlementSymbol.settle, action: settle)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .scaledFont(rowSize.detailFont)
                            .help("Settle")
                    } else {
                        Text(row.dateLabel)
                            .scaledFont(rowSize.detailFont)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: provider.symbolName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
                    .accessibilityLabel("\(provider.displayName) conversation")
                if row.isAutomation {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityLabel("Automation")
                }
                Text(folderName)
                    .truncationMode(.middle)
                if let hostName {
                    Text("·")
                    Text(hostName)
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                ConversationRowStatus(activity: row.activity, questionCount: row.questionCount, address: row.address,
                                      isProbablyDone: row.isProbablyDone)
            }
            .scaledFont(rowSize.detailFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, dotDiameter + dotSpacing)
        }
        .help("\(row.hostName) · \(row.workingDirectory)")
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isUnread ? "Unread" : "")
    }

    private var folderName: String {
        (row.workingDirectory as NSString).lastPathComponent
    }

    private var dotDiameter: CGFloat { 7 * scale }
    private var dotSpacing: CGFloat { 5 * scale }

    private var markSize: CGFloat {
        let base: CGFloat = switch rowSize {
        case .small: 10
        case .large: 13
        default: 11
        }
        return base * scale
    }
}

private struct UnsentDraftSourceRow: View, Equatable {
    let row: UnsentDraftRow
    let hostName: String?
    let open: () -> Void
    @Environment(\.sidebarRowSize) private var rowSize
    @Environment(\.interfaceScale) private var scale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.hostName == rhs.hostName }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .scaledFont(rowSize.titleFont)
                        .fontWeight(row.isSelected ? .semibold : nil)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let ageLabel = row.ageLabel {
                        Text(ageLabel)
                            .scaledFont(rowSize.detailFont)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    if let provider = row.provider {
                        Image(systemName: provider.symbolName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: markSize, height: markSize)
                            .accessibilityLabel("\(provider.displayName) draft")
                    }
                    Text((row.workingDirectory as NSString).lastPathComponent)
                        .truncationMode(.middle)
                    if let hostName {
                        Text("·")
                        Text(hostName)
                            .layoutPriority(1)
                    }
                }
                .scaledFont(rowSize.detailFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(row.workingDirectory.isEmpty ? row.hostName : "\(row.hostName) · \(row.workingDirectory)")
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    }

    private var markSize: CGFloat {
        let base: CGFloat = switch rowSize {
        case .small: 10
        case .large: 13
        default: 11
        }
        return base * scale
    }
}

private struct ConversationRowStatus: View {
    let activity: CodexGatewayDaemon.ActivityState?
    let questionCount: Int?
    let address: ConversationAddress
    let isProbablyDone: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isProbablyDone {
                Image(systemName: ConversationSettlementSymbol.settle)
                    .foregroundStyle(.green)
                    .help("Probably done")
                    .accessibilityLabel("Probably done")
            }
            if let questionCount, questionCount > 0 {
                Label("\(questionCount)", systemImage: "questionmark.bubble")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(questionCount == 1 ? "Has a question" : "\(questionCount) questions")
                    .accessibilityIdentifier("conversation-questions-\(address.id)")
            }
            if let activity, let symbol = Self.symbol(for: activity) {
                Image(systemName: symbol.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(symbol.style)
                    .help(symbol.label)
                    .accessibilityLabel(symbol.label)
            }
        }
    }

    static func symbol(for activity: CodexGatewayDaemon.ActivityState) -> (name: String, label: String, style: HierarchicalShapeStyle)? {
        switch activity {
        case .working: ("ellipsis", "Working", .primary)
        case .waiting: ("hand.raised", "Needs input", .primary)
        case .unknown: ("questionmark.circle", "Checking status", .tertiary)
        case .idle: nil
        }
    }
}

private extension SidebarRowSize {
    var titleFont: Font {
        switch self {
        case .small: .subheadline
        case .medium: .body
        case .large: .title3
        @unknown default: .body
        }
    }

    var detailFont: Font {
        switch self {
        case .small: .footnote
        case .medium: .subheadline
        case .large: .callout
        @unknown default: .subheadline
        }
    }
}

private extension NSApplication {
    var isHandlingPointerEvent: Bool {
        switch currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        default: false
        }
    }
}
#endif
