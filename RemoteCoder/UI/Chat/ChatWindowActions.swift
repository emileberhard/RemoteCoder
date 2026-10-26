import SwiftUI

struct ChatWindowCommandState: Equatable, Sendable {
    struct Host: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
    }

    let hosts: [Host]
    let selectedHostID: UUID?
    let conversation: ConversationAddress?
    let isSidebarOpen: Bool
    let isInspectorOpen: Bool
    let isPinned: Bool
    let models: [ModelOption]
    let selectedModelID: String?
    let reasoningLevels: [ReasoningSelection]
    let reasoning: ReasoningSelection
    let isFastModeOn: Bool
    let favoriteFolders: [FavoriteFolder]
    let drawerMode: ConversationDrawerMode
    let isUnreadOnly: Bool
    let isConversationSettled: Bool
    let hasDraft: Bool
    let enabledCommands: Set<ChatCommand>
}

@dynamicMemberLookup
struct ChatWindowActions: Equatable, Sendable {
    typealias Host = ChatWindowCommandState.Host

    let state: ChatWindowCommandState
    fileprivate let performer: ChatWindowActionPerformer

    subscript<Value>(dynamicMember keyPath: KeyPath<ChatWindowCommandState, Value>) -> Value {
        state[keyPath: keyPath]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state && lhs.performer === rhs.performer
    }

    func isEnabled(_ command: ChatCommand) -> Bool { state.enabledCommands.contains(command) }

    @MainActor func run(_ command: ChatCommand) { performer.context?.run(command) }

    func isOn(_ command: ChatCommand) -> Bool? {
        switch command {
        case .toggleFastMode: state.isFastModeOn
        case .unreadOnly: state.isUnreadOnly
        default: nil
        }
    }

    @MainActor func newChatOnHost(_ id: UUID) { performer.context?.newChatOnHost(id) }
    @MainActor func selectFavorite(_ favorite: FavoriteFolder) { performer.context?.selectFavorite(favorite) }
    @MainActor func selectModel(_ model: ModelOption) { performer.context?.selectModel(model) }
    @MainActor func selectReasoning(_ reasoning: ReasoningSelection) { performer.context?.selectReasoning(reasoning) }
    @MainActor func selectDrawerMode(_ mode: ConversationDrawerMode) { performer.context?.selectDrawerMode(mode) }
    @MainActor func selectHost(_ id: UUID) { performer.context?.selectHost(id) }
    @MainActor func selectConversation(_ address: ConversationAddress) { performer.context?.selectConversation(address) }
    @MainActor func unfoldedConversationRows() -> [ConversationSidebarRow] { performer.context?.unfoldedConversationRows() ?? [] }
    @MainActor func goToConversation(atPosition position: Int) { performer.context?.goToConversation(atPosition: position) }
}

@MainActor
fileprivate final class ChatWindowActionPerformer {
    fileprivate var context: ChatWindowActionContext?
}

private struct ChatWindowFocusPublication: View, Equatable {
    let actions: ChatWindowActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.actions == rhs.actions }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .focusedSceneValue(\.chatWindowActions, actions)
    }
}

enum ChatCommand: CaseIterable, Hashable, Sendable {
    case newChat, newChatInHomeFolder, newWindow, fork, chooseFolder
    case findInConversation, findNext, findPrevious
    case commandPalette, toggleSidebar, toggleInspector, refresh
    case send, stop, focusComposer, attachFile, toggleFastMode
    case togglePin, rename, copyReference, showAgents, settle, markUnread
    case unreadOnly, markAllRead, collapseAllSections, expandAllSections
    case returnToParent, previousConversation, nextConversation, nextNeedingAttention

    var shortcut: KeyboardShortcut? {
        switch self {
        case .newChat: KeyboardShortcut("n")
        case .newWindow: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .findInConversation: KeyboardShortcut("f")
        case .findNext: KeyboardShortcut("g")
        case .findPrevious: KeyboardShortcut("g", modifiers: [.command, .shift])
        case .commandPalette: KeyboardShortcut("k")
        case .toggleSidebar: KeyboardShortcut("s", modifiers: [.command, .control])
        case .toggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        case .refresh: KeyboardShortcut("r")
        case .send: KeyboardShortcut(.return)
        case .stop: KeyboardShortcut(".")
        case .focusComposer: KeyboardShortcut("l")
        case .attachFile: KeyboardShortcut("a", modifiers: [.command, .shift])
        case .returnToParent: KeyboardShortcut("[")
        case .previousConversation: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .nextConversation: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .nextNeedingAttention: KeyboardShortcut("u", modifiers: [.command, .shift])
        case .settle: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .newChatInHomeFolder, .fork, .chooseFolder, .toggleFastMode,
             .togglePin, .rename, .copyReference, .showAgents, .markUnread,
             .unreadOnly, .markAllRead, .collapseAllSections, .expandAllSections: nil
        }
    }

    var appearsInPalette: Bool {
        switch self {
        case .commandPalette, .findNext, .findPrevious: false
        default: true
        }
    }

    var systemImage: String {
        switch self {
        case .newChat, .newChatInHomeFolder: "square.and.pencil"
        case .newWindow: "macwindow.badge.plus"
        case .fork: "arrow.triangle.branch"
        case .chooseFolder: "folder"
        case .findInConversation, .findNext, .findPrevious: "magnifyingglass"
        case .commandPalette: "command"
        case .toggleSidebar: "sidebar.leading"
        case .toggleInspector: "sidebar.trailing"
        case .refresh: "arrow.clockwise"
        case .send: "arrow.up"
        case .stop: "stop"
        case .focusComposer: "character.cursor.ibeam"
        case .attachFile: "paperclip"
        case .toggleFastMode: "bolt"
        case .togglePin, .rename: "pin"
        case .copyReference: "doc.on.doc"
        case .showAgents: "person.2"
        case .settle: ConversationSettlementSymbol.settle
        case .markUnread, .unreadOnly: "envelope.badge"
        case .markAllRead: "envelope.open"
        case .collapseAllSections: "rectangle.compress.vertical"
        case .expandAllSections: "rectangle.expand.vertical"
        case .returnToParent: "chevron.left"
        case .previousConversation: "chevron.up"
        case .nextConversation: "chevron.down"
        case .nextNeedingAttention: "bell.badge"
        }
    }

    func title(in actions: ChatWindowActions?) -> String {
        switch self {
        case .newChat: "New Chat"
        case .newChatInHomeFolder: "New Chat in Home Folder"
        case .newWindow: "New Window"
        case .fork: "Fork Conversation"
        case .chooseFolder: "Choose Folder…"
        case .findInConversation: "Find in Conversation…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .commandPalette: "Command Palette…"
        case .toggleSidebar: actions?.isSidebarOpen == true ? "Hide Sidebar" : "Show Sidebar"
        case .toggleInspector: actions?.isInspectorOpen == true ? "Hide Inspector" : "Show Inspector"
        case .refresh: "Refresh"
        case .send: "Send"
        case .stop: "Stop"
        case .focusComposer: "Focus Composer"
        case .attachFile: "Attach File…"
        case .toggleFastMode: "Fast Mode"
        case .togglePin: actions?.isPinned == true ? "Unpin" : "Pin…"
        case .rename: "Rename…"
        case .copyReference: actions?.conversation.map { $0.codexDesktopLink == nil } == true ? "Copy Thread ID" : "Copy Link"
        case .showAgents: "Show Agents"
        case .settle: actions?.isConversationSettled == true ? "Unsettle Conversation" : "Settle Conversation"
        case .markUnread: "Mark as Unread"
        case .unreadOnly: "Unread Only"
        case .markAllRead: "Mark All as Read"
        case .collapseAllSections: "Collapse All Sections"
        case .expandAllSections: "Expand All Sections"
        case .returnToParent: "Back to Parent Conversation"
        case .previousConversation: "Previous Conversation"
        case .nextConversation: "Next Conversation"
        case .nextNeedingAttention: "Next Needing Attention"
        }
    }
}

extension KeyboardShortcut {
    var symbols: String {
        let modifierSymbols: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = modifierSymbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let keySymbol = switch key {
        case .return: "↩"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .escape: "⎋"
        default: String(key.character).uppercased()
        }
        return prefix + keySymbol
    }
}

extension OpenWindowAction {
    func openNewChatWindow() {
        callAsFunction(value: ConversationWindowValue.newChat(slot: UUID()))
    }
}

extension FocusedValues {
    @Entry var chatWindowActions: ChatWindowActions?
}

struct ChatWindowActionsPublisher: View {
    let workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let screen: ChatScreenModel
    let find: TranscriptFind
    let drawerLayout: ConversationDrawerLayout?
    let isSidebarOpen: Bool
    let isInspectorOpen: Bool
    let newChat: () -> Void
    let newChatInHomeFolder: () -> Void
    let newChatOnHost: (UUID) -> Void
    let toggleSidebar: () -> Void
    let toggleInspector: () -> Void
    let focusComposer: () -> Void
    let chooseFolder: () -> Void
    let returnToParent: (() -> Void)?
    let selectConversation: (ConversationAddress) -> Void
    let fork: (ConversationAddress) -> Void
    let requestPinName: (ConversationPinRequest) -> Void
    let showAgents: (ConversationAgentsModel) -> Void
    let attachFile: () -> Void
    let toggleCommandPalette: (ChatWindowActions) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var performer = ChatWindowActionPerformer()

    var body: some View {
        let context = context
        performer.context = context
        #if os(macOS)
        return ChatWindowFocusPublication(actions: ChatWindowActions(state: context.commandState, performer: performer)).equatable()
        #else
        return Color.clear.frame(width: 0, height: 0)
        #endif
    }

    private var context: ChatWindowActionContext {
        ChatWindowActionContext(
            workspace: workspace,
            window: window,
            screen: screen,
            find: find,
            drawerLayout: drawerLayout,
            isSidebarOpen: isSidebarOpen,
            isInspectorOpen: isInspectorOpen,
            newChat: newChat,
            newChatInHomeFolder: newChatInHomeFolder,
            newChatOnHost: newChatOnHost,
            toggleSidebar: toggleSidebar,
            toggleInspector: toggleInspector,
            focusComposer: focusComposer,
            chooseFolder: chooseFolder,
            returnToParent: returnToParent,
            selectConversation: selectConversation,
            fork: fork,
            requestPinName: requestPinName,
            showAgents: showAgents,
            attachFile: attachFile,
            toggleCommandPalette: toggleCommandPalette,
            openWindow: openWindow,
            performer: performer
        )
    }
}

@MainActor
fileprivate struct ChatWindowActionContext {
    let workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let screen: ChatScreenModel
    let find: TranscriptFind
    let drawerLayout: ConversationDrawerLayout?
    let isSidebarOpen: Bool
    let isInspectorOpen: Bool
    let newChat: () -> Void
    let newChatInHomeFolder: () -> Void
    let newChatOnHost: (UUID) -> Void
    let toggleSidebar: () -> Void
    let toggleInspector: () -> Void
    let focusComposer: () -> Void
    let chooseFolder: () -> Void
    let returnToParent: (() -> Void)?
    let selectConversation: (ConversationAddress) -> Void
    let fork: (ConversationAddress) -> Void
    let requestPinName: (ConversationPinRequest) -> Void
    let showAgents: (ConversationAgentsModel) -> Void
    let attachFile: () -> Void
    let toggleCommandPalette: (ChatWindowActions) -> Void
    let openWindow: OpenWindowAction
    weak var performer: ChatWindowActionPerformer?

    var commandState: ChatWindowCommandState {
        let conversation = screen.openAddress
        let isPinned = conversation.flatMap(workspace.pinnedName(for:)) != nil
        let settlement = conversationSettlement(conversation)
        let settingsModel = showsConversationSettings ? screen.selectedModel : nil
        let fastModel = settingsModel.flatMap { $0.supportsFastMode ? $0 : nil }
        var enabled = Set(ChatCommand.allCases)
        if conversation == nil {
            enabled.subtract([.fork, .togglePin, .copyReference, .markUnread])
        }
        if !isPinned { enabled.remove(.rename) }
        if !find.hasMatches { enabled.subtract([.findNext, .findPrevious]) }
        if !screen.composerSendState.canSend { enabled.remove(.send) }
        if screen.composerStopState.readyTurn == nil { enabled.remove(.stop) }
        if !acceptsComposerAttachments { enabled.remove(.attachFile) }
        if fastModel == nil { enabled.remove(.toggleFastMode) }
        if (screen.conversationAgents?.summary?.total ?? 0) == 0 { enabled.remove(.showAgents) }
        if returnToParent == nil || workspace.agentNavigation.map({ workspace.isShowingConversation(at: $0.child, on: screen) }) != true {
            enabled.remove(.returnToParent)
        }
        let canSettle = settlement == .unsettled && conversation.map { workspace.isRunning($0) } == false
        if settlement != .settled && !canSettle { enabled.remove(.settle) }
        return ChatWindowCommandState(
            hosts: workspace.settings.hosts.map { .init(id: $0.id, name: $0.displayName) },
            selectedHostID: workspace.selectedHostID,
            conversation: conversation,
            isSidebarOpen: isSidebarOpen,
            isInspectorOpen: isInspectorOpen,
            isPinned: isPinned,
            models: showsModelPicker ? workspace.modelOptions(for: screen) : [],
            selectedModelID: screen.selectedModel?.id,
            reasoningLevels: settingsModel.map { workspace.modelPickerPreferences.reasoningEfforts(for: $0).map { .effort($0) } } ?? [],
            reasoning: screen.reasoningSelection,
            isFastModeOn: fastModel != nil && screen.fastModeSelection == true,
            favoriteFolders: workspace.favoriteFolders,
            drawerMode: workspace.drawerPreferences.mode,
            isUnreadOnly: workspace.drawerPreferences.unreadOnly,
            isConversationSettled: settlement == .settled,
            hasDraft: screen.composerDocument?.hasContent == true,
            enabledCommands: enabled
        )
    }

    func run(_ command: ChatCommand) {
        guard commandState.enabledCommands.contains(command) else { return }
        switch command {
        case .newChat: newChat()
        case .newChatInHomeFolder: newChatInHomeFolder()
        case .newWindow: openWindow.openNewChatWindow()
        case .fork:
            if let address = screen.openAddress { fork(address) }
        case .chooseFolder: chooseFolder()
        case .findInConversation: find.present()
        case .findNext: find.move(.next, in: screen)
        case .findPrevious: find.move(.previous, in: screen)
        case .commandPalette: toggleCommandPaletteFromCurrentState()
        case .toggleSidebar: toggleSidebar()
        case .toggleInspector: toggleInspector()
        case .refresh: Task { await workspace.refreshAllHosts() }
        case .send: Task { _ = await workspace.send(from: screen) }
        case .stop:
            if let turn = screen.composerStopState.readyTurn { screen.stopTurn(turn) }
        case .focusComposer: focusComposer()
        case .attachFile: attachFile()
        case .toggleFastMode: screen.selectFastMode(screen.fastModeSelection != true, for: screen.activeSessionID)
        case .togglePin:
            if let address = screen.openAddress {
                if workspace.pinnedName(for: address) != nil {
                    workspace.unpin(address)
                    HapticService.shared.play(.toggleOff)
                } else {
                    requestPinName(.init(kind: .pin, address: address))
                }
            }
        case .rename:
            if let address = screen.openAddress { requestPinName(.init(kind: .rename, address: address)) }
        case .copyReference:
            if let address = screen.openAddress { HapticService.shared.copy(address.codexDesktopLink ?? address.threadID) }
        case .showAgents:
            if let agents = screen.conversationAgents { showAgents(agents) }
        case .returnToParent: returnToParent?()
        case .settle:
            guard let address = screen.openAddress else { return }
            if conversationSettlement(address) == .settled {
                workspace.unsettle([address])
            } else if workspace.settle([address]).isEmpty {
                return
            }
            HapticService.shared.play(.commit)
        case .markUnread:
            if let address = screen.openAddress { workspace.markUnread(address) }
        case .unreadOnly: workspace.drawerPreferences.unreadOnly.toggle()
        case .markAllRead: workspace.markAllRead()
        case .collapseAllSections: workspace.setAllSectionsFolded(true, in: window)
        case .expandAllSections: workspace.setAllSectionsFolded(false, in: window)
        case .previousConversation: goToConversation(.previous)
        case .nextConversation: goToConversation(.next)
        case .nextNeedingAttention:
            if let address = ConversationSidebarNavigation.nextNeedingAttention(after: screen.openAddress,
                                                                                in: unfoldedConversationRows()) {
                selectConversation(address)
            }
        }
    }

    func selectFavorite(_ favorite: FavoriteFolder) {
        workspace.selectFavorite(favorite, from: screen, ifStillShowing: screen.currentConversationID)
    }

    func selectModel(_ model: ModelOption) { workspace.selectModel(model) }
    func selectReasoning(_ reasoning: ReasoningSelection) { screen.selectReasoning(reasoning, for: screen.activeSessionID) }
    func selectDrawerMode(_ mode: ConversationDrawerMode) { workspace.drawerPreferences.mode = mode }
    func selectHost(_ id: UUID) { workspace.select(hostID: id) }

    func unfoldedConversationRows() -> [ConversationSidebarRow] {
        workspace.unfoldedSidebarRows(arrangedBy: drawerLayout ?? .live(at: .now), in: window)
    }

    private func conversationRows() -> [ConversationSidebarRow] {
        ConversationSidebarNavigation.rows(
            of: workspace.sidebarSnapshot(arrangedBy: drawerLayout ?? .live(at: .now), in: window).items
        )
    }

    func goToConversation(atPosition position: Int) {
        if let address = ConversationSidebarNavigation.address(atPosition: position, in: conversationRows()) {
            selectConversation(address)
        }
    }

    private func goToConversation(_ direction: ConversationSidebarNavigation.Direction) {
        if let address = ConversationSidebarNavigation.neighbor(direction, of: screen.openAddress, in: conversationRows()) {
            selectConversation(address)
        }
    }

    private func conversationSettlement(_ address: ConversationAddress?) -> ConversationSidebarRow.Settlement {
        guard let address else { return .unavailable }
        return workspace.settlement(of: address, capturedIn: isSidebarOpen ? drawerLayout : nil)
    }

    private var showsModelPicker: Bool {
        screen.acceptsConversationInput && !screen.isLoadingConversationSettings
            && (screen.newChatModelUnavailableReason != nil || showsConversationSettings)
    }

    private var showsConversationSettings: Bool {
        screen.acceptsConversationInput && screen.areConversationSettingsReady && screen.selectedModel != nil
    }

    private var acceptsComposerAttachments: Bool {
        screen.acceptsConversationInput && screen.currentDraft != nil && !screen.target.voice.isRecording
            && screen.currentConversationDispatchBlock != .otherClient
    }

    private func toggleCommandPaletteFromCurrentState() {
        if let performer { toggleCommandPalette(ChatWindowActions(state: commandState, performer: performer)) }
    }

}

private extension ComposerStopState {
    var readyTurn: RunningTurn? {
        if case .ready(let turn) = self { return turn }
        return nil
    }
}
