import SwiftUI

struct ConversationDetailsPresentation: ViewModifier {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    @Binding var presentedAgents: ConversationAgentsModel?
    @Binding var isInspectorPresented: Bool
    let onParentRequestSent: () -> Void

    func show(_ agents: ConversationAgentsModel) {
        presentedAgents = agents
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedAgents) { agents in
                ConversationAgentsView(workspace: workspace, model: agents, onParentRequest: { request in
                    try await workspace.sendToAgentParent(request, from: agents.address)
                    presentedAgents = nil
                    onParentRequestSent()
                }, onOpenConversation: { agent in
                    try await workspace.openAgentConversation(agent, from: agents.address)
                    presentedAgents = nil
                }, onAction: { agent, action, text, mutationID in
                    try await workspace.performAgentAction(action, on: agent, in: agents.address, text: text, mutationID: mutationID)
                })
            }
    }
}
