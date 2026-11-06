import SwiftUI

struct SubagentHeader: View {
    let screen: ChatScreenModel

    var body: some View {
        if let context = screen.subagentContext { header(context) }
    }

    private func header(_ context: SubagentContext) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                AgentIdentityDot(key: context.threadID)
                Text(context.title)
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Text(context.parentTitle.map { "Subagent of \($0)" } ?? "Subagent")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .appGlass(.standard, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("subagent-header")
    }
}

struct SubagentControls: View {
    let screen: ChatScreenModel
    let workspace: ChatWorkspaceModel
    let onViewQuestion: (QuestionPrompt) -> Void
    let onAskParent: (ConversationAddress) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("Read-only subagent", systemImage: "eye")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let question = screen.pendingQuestion {
                Button("View Question") { onViewQuestion(question) }
            }
            if let parent = screen.agentParent, let target = workspace.agentRequestTarget(above: parent) {
                Button("Ask Parent") { onAskParent(target) }
            }
            if let turn = screen.turnStopState.readyTurn {
                Button("Stop", role: .destructive) { screen.stopTurn(turn) }
                    .accessibilityIdentifier("subagent-stop")
            }
        }
        .scaledFont(.footnote.weight(.medium))
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .appGlass(.standard, in: .capsule)
    }
}
