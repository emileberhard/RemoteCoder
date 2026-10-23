import SwiftUI

struct ConversationHistoryList: View {
    var workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let snapshot: ConversationSidebarSnapshot?
    let notice: DrawerNotice?
    let undo: DrawerUndo?
    let actions: ConversationHistoryActions
    let onUndo: () -> Void
    let risingRowIDs: Set<String>
    let onInteractionChanged: (Bool) -> Void

    @State private var rowMenu = ScrollItemContextMenu<ConversationAddress>()
    @State private var isScrolling = false
    @State private var swipedEdges: Set<String> = []
    @State private var selection: Set<ConversationAddress>?
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ThemedSheetBackground()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = snapshot?.items ?? []
        let drafts = selection == nil ? snapshot?.drafts ?? [] : []

        ScrollView {
            LazyVStack(spacing: DrawerListMetrics.rowSpacing) {
                if !drafts.isEmpty {
                    draftsSection(drafts, above: items.first)
                }
                if items.isEmpty, isAnyHostLoading {
                    ProgressView("Loading history…")
                        .padding(20)
                        .appContentSurface(.standard, in: .rect(cornerRadius: 18))
                } else if items.isEmpty, snapshot?.hostStates.contains(where: { $0.canLoadMore || $0.hasDiscardedHeaders || !$0.unloadedPins.isEmpty }) == true {
                    emptyCard(systemImage: "clock.arrow.circlepath", title: "More history not loaded")
                } else if items.isEmpty {
                    emptyState
                } else {
                    ForEach(items) { item in
                        switch item {
                        case let .pinnedHeader(summary):
                            sectionHeader(summary, identifier: "drawer-pinned") {
                                workspace.drawerPreferences.isPinnedFolded = summary.fold == .expanded
                            } title: {
                                HStack(spacing: 6) {
                                    Image(systemName: "pin.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text("Pinned")
                                }
                            }
                            .sectionHeaderSpacing(isFirst: drafts.isEmpty && item.id == items.first?.id)
                        case let .automationsHeader(summary):
                            sectionHeader(summary, identifier: "drawer-automations") {
                                workspace.drawerPreferences.isAutomationsFolded = summary.fold == .expanded
                            } title: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text("Automations")
                                }
                            }
                            .sectionHeaderSpacing(isFirst: drafts.isEmpty && item.id == items.first?.id)
                        case let .moreAutomations(hiddenCount):
                            moreButton("Show \(hiddenCount) more") {
                                withAnimation(reduceMotion ? nil : .snappy) { window.revealAllAutomations() }
                            }
                        case .chatsHeader:
                            Text("Chats")
                                .font(.headline)
                                .sectionHeaderFrame()
                                .accessibilityAddTraits(.isHeader)
                                .sectionHeaderSpacing(isFirst: false)
                        case let .project(header):
                            sectionHeader(header.summary, identifier: "drawer-project-\(header.key)") {
                                workspace.setFolded(header.summary.fold == .expanded, project: header.key, in: window)
                            } title: {
                                projectTitle(header)
                            }
                            .sectionHeaderSpacing(isFirst: drafts.isEmpty && item.id == items.first?.id)
                        case let .more(key, hiddenCount):
                            moreButton("Show \(hiddenCount) more") {
                                withAnimation(reduceMotion ? nil : .snappy) { window.reveal(project: key) }
                            }
                        case let .settledHeader(summary):
                            sectionHeader(summary, identifier: "drawer-settled") {
                                workspace.drawerPreferences.isSettledFolded = summary.fold == .expanded
                            } title: {
                                HStack(spacing: 6) {
                                    Image(systemName: ConversationSettlementSymbol.shelf)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text("Settled")
                                }
                            }
                            .sectionHeaderSpacing(isFirst: drafts.isEmpty && item.id == items.first?.id)
                        case let .moreSettled(hiddenCount):
                            moreButton("Show \(hiddenCount) more") {
                                withAnimation(reduceMotion ? nil : .snappy) { window.revealMoreSettled() }
                            }
                        case let .row(row):
                            rowView(row)
                                .zIndex(risingRowIDs.contains(row.id) ? 1 : 0)
                                .transition(.opacity)
                        }
                    }
                }
                ConversationHistoryLoadingFooter(workspace: workspace, window: window, states: snapshot?.hostStates ?? [], open: actions.open)
                    .fontWeight(.medium)
                    .foregroundStyle(themeStore.theme.colors.accentTint)
                    .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 0.99, pressedOpacity: 0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .contentMargins(.top, 6, for: .scrollContent)
        .contentMargins(.bottom, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .swipeActionsContainer()
        .onScrollPhaseChange { _, phase in
            isScrolling = phase != .idle
            reportInteraction()
        }
        .onChange(of: rowMenu.liftedID) { reportInteraction() }
        .onDisappear {
            isScrolling = false
            swipedEdges = []
            onInteractionChanged(false)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            header.scrollItemMenuObstruction(rowMenu)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if let selection {
                selectionBar(selection, items: items)
                    .scrollItemMenuObstruction(rowMenu)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                statusMessages
                    .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: notice)
                    .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: undo)
            }
        }
        .refreshable { await workspace.refreshAllHosts() }
    }

    @ViewBuilder
    private func rowView(_ row: ConversationSidebarRow) -> some View {
        let isSelecting = selection != nil
        ConversationRow(row: row, actions: actions, contextMenu: rowMenu,
                        selection: selection.map { $0.contains(row.address) },
                        toggleSelection: { toggleSelection(row.address) })
            .equatable()
            // Host-qualified, so automation and VoiceOver can name
            // the exact row on the exact gateway.
            .accessibilityIdentifier("conversation-row-\(row.id)")
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !isSelecting {
                    let toggle = actions.readToggle(for: row)
                    Button(action: toggle.perform) {
                        Label(row.isUnread ? "Read" : "Unread", systemImage: toggle.systemImage)
                    }
                    .tint(themeStore.theme.colors.accentTint)
                }
            } onPresentationChanged: { shown in
                swipeChanged(row.id + "|leading", shown: shown)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if isSelecting {
                    EmptyView()
                } else if row.isSettled {
                    Button { actions.unsettle([row.address]) } label: {
                        Label("Unsettle", systemImage: ConversationSettlementSymbol.unsettle)
                    }
                    .tint(.indigo)
                } else if row.canSettle {
                    Button { actions.settle([row.address]) } label: {
                        Label("Settle", systemImage: ConversationSettlementSymbol.settle)
                    }
                    .tint(.green)
                }
            } onPresentationChanged: { shown in
                swipeChanged(row.id + "|trailing", shown: shown)
            }
    }

    @ViewBuilder
    private func draftsSection(_ drafts: [UnsentDraftRow], above firstItem: ConversationSidebarItem?) -> some View {
        Text("Drafts")
            .font(.headline)
            .sectionHeaderFrame()
            .accessibilityAddTraits(.isHeader)
            .sectionHeaderSpacing(isFirst: true)
        ForEach(drafts) { draft in
            UnsentDraftRowView(row: draft, open: { actions.openDraft(draft.address) },
                               discard: { actions.discardDraft(draft.address) })
                .equatable()
                .accessibilityIdentifier("unsent-draft-\(draft.address.draftID)")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { actions.discardDraft(draft.address) } label: {
                        Label("Discard", systemImage: "trash")
                    }
                } onPresentationChanged: { shown in
                    swipeChanged("draft-\(draft.address.draftID)|trailing", shown: shown)
                }
                .transition(.opacity)
        }
        if let hidden = snapshot?.hiddenDraftCount, hidden > 0 {
            moreButton("Show \(hidden) more") {
                withAnimation(reduceMotion ? nil : .snappy) { window.revealAllDrafts() }
            }
        }
        if case .row? = firstItem {
            Text("Chats")
                .font(.headline)
                .sectionHeaderFrame()
                .accessibilityAddTraits(.isHeader)
                .sectionHeaderSpacing(isFirst: false)
        }
    }

    private func swipeChanged(_ edge: String, shown: Bool) {
        if shown { swipedEdges.insert(edge) } else { swipedEdges.remove(edge) }
        reportInteraction()
    }

    private func reportInteraction() {
        onInteractionChanged(isScrolling || !swipedEdges.isEmpty || rowMenu.liftedID != nil)
    }

    @ViewBuilder
    private func sectionHeader(_ summary: ConversationSectionSummary, identifier: String,
                               toggle: @escaping () -> Void, @ViewBuilder title: () -> some View) -> some View {
        if summary.fold == .searching {
            title()
                .font(.headline)
                .sectionHeaderFrame()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
        } else {
            foldableHeader(summary, identifier: identifier, toggle: toggle, title: title)
        }
    }

    private func foldableHeader(_ summary: ConversationSectionSummary, identifier: String,
                                toggle: @escaping () -> Void, @ViewBuilder title: () -> some View) -> some View {
        let isFolded = summary.fold == .folded
        return Button(action: toggle) {
            HStack(spacing: 8) {
                title()
                Spacer(minLength: 8)
                if isFolded {
                    if let liveActivity = summary.liveActivity {
                        ConversationActivityIndicator(state: liveActivity, style: .labeled)
                    }
                    if summary.unreadCount > 0 {
                        Circle()
                            .fill(themeStore.theme.colors.accentTint)
                            .frame(width: 8, height: 8)
                    }
                    Text(summary.rowCount, format: .number)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(themeStore.theme.colors.accentTint)
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                    .accessibilityHidden(true)
            }
            .font(.headline)
            .sectionHeaderFrame()
            .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 0.99, pressedOpacity: 0.8))
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(foldValue(summary, isFolded: isFolded))
        .accessibilityIdentifier(identifier)
    }

    private func projectTitle(_ header: ConversationProjectHeader) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(header.title)
                .lineLimit(1)
                .truncationMode(.head)
            if let hostName = header.hostName {
                Text(hostName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.theme.colors.accentTint)
                    .lineLimit(1)
            }
        }
    }

    private func foldValue(_ summary: ConversationSectionSummary, isFolded: Bool) -> String {
        guard isFolded else { return "Expanded" }
        let chats = "Collapsed, \(summary.rowCount) \(summary.rowCount == 1 ? "chat" : "chats")"
        return summary.unreadCount > 0 ? "\(chats), \(summary.unreadCount) unread" : chats
    }

    private func moreButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(themeStore.theme.colors.accentTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 0.99, pressedOpacity: 0.8))
    }

    private func toggleSelection(_ address: ConversationAddress) {
        guard var chosen = selection else { return }
        if chosen.remove(address) == nil { chosen.insert(address) }
        selection = chosen
    }

    private func selectionBar(_ chosen: Set<ConversationAddress>, items: [ConversationSidebarItem]) -> some View {
        let rows = items.compactMap { item -> ConversationSidebarRow? in
            guard case let .row(row) = item, chosen.contains(row.address) else { return nil }
            return row
        }
        let addresses = rows.map(\.address)
        let unsettles = !rows.isEmpty && rows.allSatisfy(\.isSettled)
        let settleable = rows.filter(\.canSettle).map(\.address)
        return HStack(spacing: 12) {
            Button {
                actions.markRead(addresses)
                selection = nil
            } label: {
                Label("Mark Read", systemImage: "envelope.open")
            }
            .disabled(addresses.isEmpty)
            Spacer(minLength: 0)
            Text(addresses.isEmpty ? "Select chats" : "\(addresses.count) selected")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            if unsettles {
                Button {
                    actions.unsettle(addresses)
                    selection = nil
                } label: {
                    Label("Unsettle \(addresses.count)", systemImage: ConversationSettlementSymbol.unsettle)
                }
            } else {
                Button {
                    actions.settle(settleable)
                    selection = nil
                } label: {
                    Label(settleable.isEmpty ? "Settle" : "Settle \(settleable.count)", systemImage: ConversationSettlementSymbol.settle)
                }
                .disabled(settleable.isEmpty)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.semibold))
        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.97, pressedOpacity: 0.9))
        .padding(.horizontal, 18)
        .frame(height: 50)
        .appGlass(.standard, in: .capsule, interactive: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var isAnyHostLoading: Bool {
        snapshot?.hostStates.contains { $0.isLoading } ?? true
    }

    /// A failing gateway keeps its cached rows, so the error has to say which
    /// host is unreachable instead of letting the list look merely short.
    @ViewBuilder
    private var statusMessages: some View {
        let reporting = snapshot?.hostStates.filter { $0.status != nil } ?? []
        if notice != nil || undo != nil || reporting.isEmpty == false {
            VStack(alignment: .leading, spacing: 0) {
                if let undo {
                    HStack(spacing: 12) {
                        Text(undo.message)
                        Spacer(minLength: 0)
                        Button(action: onUndo) {
                            Text("Undo")
                                .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
                                .contentShape(.rect)
                        }
                        .foregroundStyle(themeStore.theme.colors.accentTint)
                        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.96, pressedOpacity: 0.9))
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 50)
                }
                if notice != nil || reporting.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        if let notice {
                            Text(notice.message)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                        ForEach(reporting) { state in
                            HostStatusText(state: state, namingHost: workspace.hasMultipleHosts)
                        }
                    }
                    .font(.footnote)
                    .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appGlass(.standard, in: .rect(cornerRadius: 25))
            .scrollItemMenuObstruction(rowMenu)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if workspace.drawerPreferences.unreadOnly {
            VStack(spacing: 12) {
                emptyCard(systemImage: "checkmark.circle", title: "All caught up")
                Button("Show All Chats") { workspace.drawerPreferences.unreadOnly = false }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeStore.theme.colors.accentTint)
                    .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.97, pressedOpacity: 0.9))
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("No conversations yet")
                    .font(.headline)
            }
            .padding(20)
            .appContentSurface(.standard, in: .rect(cornerRadius: 18))
        }
    }

    private func emptyCard(systemImage: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .appContentSurface(.standard, in: .rect(cornerRadius: 18))
    }
}

extension ConversationHistoryList {
    /// Tap starts a chat on the selected host; the menu names every configured
    /// destination so a new prompt's machine is an explicit choice.
    @ViewBuilder
    fileprivate var newConversationControl: some View {
        if workspace.hasMultipleHosts, let selectedHostID = workspace.selectedHostID {
            AppMenu(trigger: .icon) {
                ForEach(workspace.settings.hosts) { host in
                    Button {
                        actions.startNew(host.id)
                    } label: {
                        if host.id == selectedHostID {
                            Label(host.displayName, systemImage: "checkmark")
                        } else {
                            Text(host.displayName)
                        }
                    }
                }
            } label: {
                GlassToolbarControl(height: 44, horizontalPadding: 0) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .semibold))
                }
            } primaryAction: {
                actions.startNew(selectedHostID)
            }
            .accessibilityLabel("New Conversation")
            .accessibilityHint("Long press to choose a host")
            .accessibilityIdentifier("new-conversation")
        } else if let selectedHostID = workspace.selectedHostID {
            GlassCircleButton(systemImage: "square.and.pencil", symbolSize: 19) { actions.startNew(selectedHostID) }
                .accessibilityLabel("New Conversation")
                .accessibilityIdentifier("new-conversation")
        }
    }

    @ViewBuilder
    fileprivate var header: some View {
        // Keep adjacent controls separate: a blending distance above
        // the HStack gap distorts the circular surfaces even at rest.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 12) {
                GlassCircleButton(systemImage: "gearshape", action: actions.showSettings)
                    .accessibilityLabel("Settings")
                ConversationDrawerFilterButton(workspace: workspace, window: window) {
                    withAnimation(reduceMotion ? nil : .snappy) { selection = [] }
                }
                Spacer(minLength: 0)
                UsageRingsControl(workspace: workspace)
                Spacer(minLength: 0)
                if selection != nil {
                    Button("Done") {
                        withAnimation(reduceMotion ? nil : .snappy) { selection = nil }
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.96, pressedOpacity: 0.9))
                    .appGlass(.standard, in: .capsule, interactive: true)
                } else {
                    newConversationControl
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

private enum DrawerListMetrics {
    static let rowSpacing: CGFloat = 10
}

private extension View {
    func sectionHeaderFrame() -> some View {
        frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
            .padding(.horizontal, 12)
    }

    func sectionHeaderSpacing(isFirst: Bool) -> some View {
        padding(.top, isFirst ? 0 : 12)
            .padding(.bottom, -DrawerListMetrics.rowSpacing)
    }
}
