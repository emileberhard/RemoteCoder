#if os(macOS)
import SwiftUI

struct ConversationDetailsPresentation: ViewModifier {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    @Binding var presentedAgents: ConversationAgentsModel?
    @Binding var isInspectorPresented: Bool
    let onParentRequestSent: () -> Void

    func show(_: ConversationAgentsModel) {
        isInspectorPresented = true
    }

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $isInspectorPresented) {
                ConversationInspector(workspace: workspace, screen: screen, onParentRequestSent: onParentRequestSent)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
    }
}

private struct ConversationInspector: View {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    let onParentRequestSent: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let agents = screen.conversationAgents
        NavigationStack {
            Form {
                Section("Conversation") {
                    LabeledContent("Host", value: workspace.conversationTargetName(of: screen))
                    LabeledContent("Folder") {
                        Text(folder).textSelection(.enabled)
                    }
                    LabeledContent("Model", value: settings.model)
                    LabeledContent("Reasoning", value: settings.reasoning)
                    LabeledContent("Context", value: context)
                }
                Section("Agents") {
                    if let agents {
                        agentRows(agents)
                    } else {
                        Text("No Agents").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .id(agents?.id)
        .task(id: scenePhase) {
            guard scenePhase == .active, let agents else { return }
            await agents.refreshIfNeeded()
        }
    }

    @ViewBuilder
    private func agentRows(_ agents: ConversationAgentsModel) -> some View {
        let earlier = agents.sections.earlier
        links(agents, rows: agents.sections.recent)
        if !earlier.isEmpty {
            EarlierConversationAgents(count: earlier.count) { links(agents, rows: earlier) }
        }
        if agents.hasLoaded, let error = agents.error {
            AgentNote(text: error)
        }
        ForEach(agents.warnings, id: \.self) { AgentNote(text: $0) }
        ConversationAgentsPlaceholder(model: agents)
    }

    private func links(_ agents: ConversationAgentsModel, rows: [ConversationAgentRow]) -> some View {
        ConversationAgentLinks(model: agents, rows: rows, onParentRequest: { request in
            try await workspace.sendToAgentParent(request, from: agents.address)
            onParentRequestSent()
        }, onOpenConversation: { agent in
            try await workspace.openAgentConversation(agent, from: agents.address)
        }, onAction: { agent, action, text, mutationID in
            try await workspace.performAgentAction(action, on: agent, in: agents.address, text: text, mutationID: mutationID)
        })
    }

    private var folder: String {
        guard let path = screen.workingDirectory else { return "Not chosen" }
        return WorkingDirectoryPathFormatter.displayPath(path, remoteHomePath: screen.target.remoteHomePath)
    }

    private var settings: (model: String, reasoning: String) {
        if screen.isLoadingConversationSettings { return ("Loading…", "Loading…") }
        guard screen.areConversationSettingsReady, let model = screen.selectedModel else { return ("Unknown", "Unknown") }
        return (model.displayName, screen.reasoningSelection.label)
    }

    private var context: String {
        guard let usage = screen.contextWindowUsage else { return "Unknown" }
        return "\(usage.usedPercent)% · \(usage.tokensText)"
    }
}
#endif
