import SwiftUI

struct SubagentsPill: View {
    let roster: ConversationAgentRoster
    let isExpanded: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.surfaceVisibility) private var surfaceVisibility

    var body: some View {
        StatusPill(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                Text(roster.count == 1 ? "1 subagent" : "\(roster.count) subagents")
                if roster.isWorking {
                    WorkingSymbol(systemName: "ellipsis", tint: .primary, isAnimating: animates)
                }
            }
        }
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides subagents" : "Shows subagents")
        .accessibilityIdentifier("open-agents")
    }

    private var animates: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: surfaceVisibility.isVisible, reduceMotion: reduceMotion)
    }
}

struct AgentRoster: View {
    let model: ConversationAgentsModel
    let workspace: ChatWorkspaceModel
    let onOpen: (ConversationAddress) -> Void
    @State private var placement: ConversationAddress?
    @State private var failure: String?
    @InterfaceScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 220
    @InterfaceScaledMetric(relativeTo: .body) private var maxWidth: CGFloat = 400
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let roster = model.roster
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section("Active", roster.active)
                section("Done", roster.done)
                notes
            }
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .appGlass(.standard, in: .rect(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: maxWidth)
        .sheet(item: $placement) { address in
            AgentPlacementPicker(agent: address, workspace: workspace)
                .chatPresentationDiagnostics("sheet-move-agent")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshIfNeeded()
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ agents: [ConversationAgent]) -> some View {
        if !agents.isEmpty {
            Text(title)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(agents, id: \.identity) { agent in
                let address = agent.capabilities.openConversation ? agent.address(localHostID: model.address.hostID) : nil
                AgentRosterRow(agent: agent, isOpenable: address != nil) {
                    if let address { onOpen(address) }
                }
                .contextMenu { menu(for: agent) }
            }
        }
    }

    @ViewBuilder
    private func menu(for agent: ConversationAgent) -> some View {
        if let address = agent.address(localHostID: model.address.hostID) {
            Button("Move to Sidebar", systemImage: "sidebar.left") { run { try await workspace.moveAgent(address, under: nil) } }
            Button("Move Under…", systemImage: "person.2") { placement = address }
        }
        if agent.capabilities.stop {
            Divider()
            Button("Stop Agent", systemImage: "stop.circle", role: .destructive) {
                run {
                    try await workspace.performAgentAction(.stop, on: agent, in: model.address, text: "", mutationID: UUID())
                    model.invalidate()
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        let messages = [failure, model.hasLoaded ? model.error : nil].compactMap { $0 } + model.warnings
        if !messages.isEmpty || model.coverage.contains(where: { $0.state != .ok }) {
            VStack(alignment: .leading, spacing: 4) {
                ClusterCoverageStrip(coverage: model.coverage)
                ForEach(messages, id: \.self) { AgentNote(text: $0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                failure = nil
            } catch is CancellationError {
            } catch {
                HapticService.shared.play(.error)
                failure = error.localizedDescription
            }
        }
    }
}

private struct AgentRosterRow: View {
    let agent: ConversationAgent
    let isOpenable: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                AgentIdentityDot(key: agent.threadId ?? agent.identity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    AgentStatusLabel(agent: agent)
                }
                Spacer(minLength: 8)
                if let finished {
                    Text(finished, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if isOpenable {
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .selection, pressedScale: 0.99, pressedOpacity: 0.7))
        .disabled(!isOpenable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isOpenable ? "Opens the subagent's conversation" : "")
        .accessibilityIdentifier("agent-\(agent.identity)")
    }

    private var finished: Date? {
        guard [.completed, .interrupted, .failed].contains(agent.state), let at = agent.lastActiveAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(at))
    }
}

private struct AgentStatusLabel: View {
    let agent: ConversationAgent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.surfaceVisibility) private var surfaceVisibility

    var body: some View {
        HStack(spacing: 4) {
            if agent.state == .working {
                WorkingSymbol(systemName: "ellipsis", tint: .secondary,
                    isAnimating: energyPolicy.animatesDecorations(sceneActive: scenePhase == .active,
                        visible: surfaceVisibility.isVisible, reduceMotion: reduceMotion))
            }
            Text(agent.intentState.map(\.title) ?? agent.state.title)
        }
        .scaledFont(.caption)
        .foregroundStyle(tint)
        .lineLimit(1)
    }

    private var tint: Color {
        switch agent.state {
        case .waiting: .orange
        case .failed: .red
        case .working, .completed, .interrupted, .unknown, .removed: .secondary
        }
    }
}

struct AgentIdentityDot: View {
    let key: String
    @InterfaceScaledMetric(relativeTo: .body) private var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Self.color(for: key))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func color(for key: String) -> Color {
        let palette: [Color] = [.blue, .green, .purple, .pink, .teal, .indigo]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct AgentNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
    }
}

@MainActor
final class AgentConversationOpener {
    private let hostID: UUID
    private let action: (ConversationAddress) -> Void

    init(hostID: UUID, action: @escaping (ConversationAddress) -> Void) {
        self.hostID = hostID
        self.action = action
    }

    func open(threadID: String) {
        action(ConversationAddress(hostID: hostID, threadID: threadID))
    }
}

extension EnvironmentValues {
    @Entry var agentConversationOpener: AgentConversationOpener? = nil
}
