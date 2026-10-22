#if os(macOS)
import SwiftUI

struct ChatScreenChrome: ViewModifier {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    let isReturningToParent: Bool
    let onReturnToParent: () -> Void
    let onOpenConversations: (() -> Void)?
    let onChooseFolder: () -> Void
    let onNewChatInHome: () -> Void
    let onNewChatOnHost: (UUID) -> Void
    let isInspectorOpen: Bool
    let toggleInspector: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle("\(workspace.conversationTargetName(of: screen)) · \(folderTitle)")
            .toolbar(id: "chat") {
                ToolbarItem(id: "return-to-parent", placement: .navigation) { returnToParentButton }
                    .hidden(!isShowingAgentChild)
                ToolbarItem(id: "folder", placement: .primaryAction) { folderMenu }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(id: "stop", placement: .primaryAction) { stopButton }
                ToolbarItem(id: "new-chat", placement: .primaryAction) { newChatMenu }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(id: "inspector", placement: .primaryAction) { inspectorButton }
            }
    }

    private var title: String {
        let list = screen.target.conversationList
        guard let threadID = screen.openThreadID,
              let header = list.threads.first(where: { $0.id == threadID }) ?? screen.activeConversation
        else { return "New Chat" }
        return ConversationSidebarProjection.title(for: header, pinnedName: list.pinnedName(for: threadID))
    }

    private var folderTitle: String {
        guard let path = screen.workingDirectory else { return "Choose Folder" }
        let condensed = WorkingDirectoryPathFormatter.condensedPath(path, remoteHomePath: screen.target.remoteHomePath)
        return condensed == "~" ? "Home" : condensed
    }

    private var isShowingAgentChild: Bool {
        guard let navigation = workspace.agentNavigation else { return false }
        return workspace.isShowingConversation(at: navigation.child, on: screen)
    }

    private var returnToParentButton: some View {
        Button("Back", systemImage: "chevron.backward", action: onReturnToParent)
            .disabled(isReturningToParent)
            .help("Return to the parent conversation")
            .accessibilityLabel("Return to parent conversation")
            .accessibilityIdentifier("return-to-parent")
    }

    private var folderMenu: some View {
        let contextID = screen.currentConversationID
        let remoteHomePath = screen.target.remoteHomePath
        let favorites = workspace.favoriteFolders
        return AppMenu(trigger: .toolbarItem) {
            ForEach(favorites) { favorite in
                Button {
                    workspace.selectFavorite(favorite, from: screen, ifStillShowing: contextID)
                } label: {
                    Text(favorite.displayPath)
                    if favorite.showsHostLabel { Text(favorite.hostName) }
                }
            }
            if !favorites.isEmpty { Divider() }
            Button("Choose Folder…", action: onChooseFolder)
        } label: {
            Label("Working Folder", systemImage: "folder")
        } primaryAction: {
            onChooseFolder()
        }
        .help("Choose the working folder or open a favorite")
        .accessibilityValue(screen.workingDirectory.map {
            WorkingDirectoryPathFormatter.displayPath($0, remoteHomePath: remoteHomePath)
        } ?? "Not chosen")
        .accessibilityIdentifier("active-host")
    }

    private var stopButton: some View {
        let state = screen.composerStopState
        return Button("Stop", systemImage: "stop.fill") {
            if case .ready(let turn) = screen.composerStopState { screen.stopTurn(turn) }
        }
        .disabled(!canStop(state))
        .help("Stop the running turn")
        .accessibilityLabel(state == .stopping ? "Stopping" : "Stop")
        .accessibilityIdentifier("toolbar-stop")
    }

    private func canStop(_ state: ComposerStopState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private var newChatMenu: some View {
        AppMenu(trigger: .toolbarItem) {
            Button("New Chat in Home", action: onNewChatInHome)
            if workspace.hasMultipleHosts {
                Divider()
                ForEach(workspace.settings.hosts) { host in
                    Button("New Chat on \(host.displayName)") { onNewChatOnHost(host.id) }
                }
            }
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        } primaryAction: {
            screen.startNewConversation()
        }
        .help("Start a new chat in this folder")
        .accessibilityIdentifier("new-chat")
    }

    private var inspectorButton: some View {
        Button("Inspector", systemImage: "sidebar.trailing", action: toggleInspector)
            .help(isInspectorOpen ? "Hide the inspector" : "Show the inspector")
            .accessibilityLabel(isInspectorOpen ? "Hide Inspector" : "Show Inspector")
            .accessibilityIdentifier("toggle-inspector")
    }
}
#endif
