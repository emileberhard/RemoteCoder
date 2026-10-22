import SwiftUI

struct ChatCommands: Commands {
    @FocusedValue(\.chatWindowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command(.newChat)
            command(.newChatInHomeFolder)
            ForEach(actions?.hosts ?? []) { host in
                Button("New Chat on \(host.name)") { actions?.newChatOnHost(host.id) }
                    .disabled((actions?.hosts.count ?? 0) < 2)
            }
            Button(ChatCommand.newWindow.title(in: actions)) { openWindow.openNewChatWindow() }
                .keyboardShortcut(ChatCommand.newWindow.shortcut)
            Divider()
            command(.fork)
            command(.chooseFolder)
        }
        CommandGroup(before: .textEditing) {
            command(.findInConversation)
            command(.findNext)
            command(.findPrevious)
            Divider()
        }
        CommandGroup(before: .sidebar) {
            command(.toggleSidebar)
            command(.toggleInspector)
            Divider()
            drawerModePicker
            toggle(.unreadOnly)
            command(.collapseAllSections)
            command(.expandAllSections)
            command(.markAllRead)
            Divider()
            command(.refresh)
            Divider()
        }
        CommandMenu("Conversation") {
            command(.send)
            command(.stop)
            command(.focusComposer)
            Divider()
            modelPicker
            reasoningPicker
            toggle(.toggleFastMode)
            Divider()
            command(.attachFile)
            Divider()
            command(.togglePin)
            command(.rename)
            command(.copyReference)
            command(.showAgents)
            Divider()
            command(.markUnread)
            command(.settle)
        }
        CommandMenu("Go") {
            command(.commandPalette)
            command(.returnToParent)
            Divider()
            command(.previousConversation)
            command(.nextConversation)
            command(.nextNeedingAttention)
            Divider()
            ForEach(1...9, id: \.self) { position in
                Button("Conversation \(position)") { actions?.goToConversation(atPosition: position) }
                    .keyboardShortcut(KeyEquivalent(Character("\(position)")))
                    .disabled(actions == nil)
            }
            Divider()
            hostPicker
        }
    }

    private func command(_ command: ChatCommand) -> some View {
        Button(command.title(in: actions)) { actions?.run(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(actions?.isEnabled(command) != true)
    }

    private func toggle(_ command: ChatCommand) -> some View {
        Toggle(command.title(in: actions), isOn: Binding(
            get: { actions?.isOn(command) == true },
            set: { _ in actions?.run(command) }
        ))
        .disabled(actions?.isEnabled(command) != true)
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { actions?.selectedModelID },
            set: { id in
                if let model = actions?.models.first(where: { $0.id == id }) { actions?.selectModel(model) }
            }
        )) {
            ForEach(actions?.models ?? []) { model in
                Text(model.displayName).tag(Optional(model.id))
            }
        }
        .disabled(actions?.models.isEmpty ?? true)
    }

    private var reasoningPicker: some View {
        Picker("Reasoning", selection: Binding(
            get: { actions?.reasoning },
            set: { selection in
                if let selection { actions?.selectReasoning(selection) }
            }
        )) {
            ForEach(actions?.reasoningLevels ?? []) { level in
                Text(level.label).tag(Optional(level))
            }
        }
        .disabled(actions?.reasoningLevels.isEmpty ?? true)
    }

    private var drawerModePicker: some View {
        Picker("Sidebar", selection: Binding(
            get: { actions?.drawerMode },
            set: { if let mode = $0 { actions?.selectDrawerMode(mode) } }
        )) {
            Text("Priority").tag(Optional(ConversationDrawerMode.priority))
            Text("Projects").tag(Optional(ConversationDrawerMode.projects))
        }
        .disabled(actions == nil)
    }

    private var hostPicker: some View {
        Picker("Switch Host", selection: Binding(
            get: { actions?.selectedHostID },
            set: { if let id = $0 { actions?.selectHost(id) } }
        )) {
            ForEach(actions?.hosts ?? []) { host in
                Text(host.name).tag(Optional(host.id))
            }
        }
        .disabled((actions?.hosts.count ?? 0) < 2)
    }
}
