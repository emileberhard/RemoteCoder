import SwiftUI

struct ConversationAgentsView: View {
    let workspace: ChatWorkspaceModel
    @Bindable var model: ConversationAgentsModel
    let onParentRequest: (String) async throws -> Void
    let onOpenConversation: (ConversationAgent) async throws -> Void
    let onAction: (ConversationAgent, ConversationAgentAction, String, UUID) async throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let recent = model.sections.recent
            let earlier = model.sections.earlier
            List {
                if model.coverage.contains(where: { $0.state != .ok }) {
                    Section { ClusterCoverageStrip(coverage: model.coverage) }
                }
                Group {
                    if !recent.isEmpty {
                        Section { agentLinks(recent) }
                    }
                    if !earlier.isEmpty {
                        Section {
                            EarlierConversationAgents(count: earlier.count) { agentLinks(earlier) }
                        }
                    }
                    if model.hasLoaded, let error = model.error {
                        Section { AgentNote(text: error) }
                    }
                    if !model.warnings.isEmpty {
                        Section {
                            ForEach(model.warnings, id: \.self) { AgentNote(text: $0) }
                        }
                    }
                }
            }
            .overlay { ConversationAgentsPlaceholder(model: model) }
            .navigationTitle("Agents")
            .inlineNavigationTitle()
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        HapticService.shared.play(.disclosure)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshIfNeeded()
        }
    }

    private func agentLinks(_ rows: [ConversationAgentRow]) -> some View {
        ConversationAgentLinks(workspace: workspace, model: model, rows: rows, onParentRequest: onParentRequest,
                               onOpenConversation: onOpenConversation, onAction: onAction)
    }
}

struct ConversationAgentLinks: View {
    let workspace: ChatWorkspaceModel
    let model: ConversationAgentsModel
    let rows: [ConversationAgentRow]
    let onParentRequest: (String) async throws -> Void
    let onOpenConversation: (ConversationAgent) async throws -> Void
    let onAction: (ConversationAgent, ConversationAgentAction, String, UUID) async throws -> Void

    var body: some View {
        ForEach(rows) { row in
            NavigationLink {
                ConversationAgentDetail(workspace: workspace, model: model, agentID: row.id, onParentRequest: onParentRequest, onOpenConversation: onOpenConversation, onAction: onAction)
            } label: {
                AgentRow(row: row, coverage: row.agent.ownerHostId.flatMap { model.coverageByHost[$0] })
            }
            .accessibilityIdentifier("agent-\(row.id)")
        }
    }
}

struct EarlierConversationAgents<Content: View>: View {
    let count: Int
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            LabeledContent("Earlier", value: count, format: .number)
        }
    }
}

struct ConversationAgentsPlaceholder: View {
    let model: ConversationAgentsModel

    var body: some View {
        if !model.hasLoaded {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Agents Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                ProgressView()
            }
        } else if model.agents.isEmpty && model.warnings.isEmpty && model.error == nil && model.coverage.allSatisfy({ $0.state == .ok }) {
            ContentUnavailableView("No Agents", systemImage: "person.2")
        }
    }
}

struct SubagentsPill: View {
    let agents: ConversationAgentsModel
    let recent: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                Text(recent == 0 ? "Subagents" : recent == 1 ? "1 subagent" : "\(recent) subagents")
                if agents.agents.contains(where: { $0.state == .working }) {
                    WorkingSymbol(systemName: "ellipsis", tint: .primary, isAnimating: animates)
                }
            }
            .scaledFont(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .appGlass(.standard, in: .capsule)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.97))
        .accessibilityHint("Shows subagents")
        .accessibilityIdentifier("open-agents")
    }

    private var animates: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible, reduceMotion: reduceMotion)
    }
}

private struct AgentRow: View {
    let row: ConversationAgentRow
    let coverage: ClusterCoverage?
    @InterfaceScaledMetric(relativeTo: .body) private var indent: CGFloat = 20

    var body: some View {
        HStack(spacing: 12) {
            AgentStateSymbol(state: row.agent.state)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.agent.title).lineLimit(2)
                if let coverage {
                    AgentHostBadge(name: coverage.name ?? coverage.hostId.uuidString, reachability: coverage.state)
                }
                if let state = row.agent.intentState {
                    Text(state.title)
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * indent)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentHostBadge: View {
    let name: String
    let reachability: ClusterCoverage.State

    var body: some View {
        Label(label, systemImage: symbol)
            .scaledFont(.caption).foregroundStyle(.secondary)
    }

    private var label: String {
        switch reachability {
        case .ok: name
        case .unreachable: "\(name) · Unreachable"
        case .unsupported: "\(name) · Too old"
        case .stale: "\(name) · Stale"
        case .refused: "\(name) · Refused"
        case .unavailable: "\(name) · Unavailable"
        case .unknown: "\(name) · Unknown"
        }
    }

    private var symbol: String {
        switch reachability {
        case .ok: "server.rack"
        case .unreachable: "network.slash"
        case .unsupported: "clock.badge.exclamationmark"
        case .stale: "clock.badge.exclamationmark"
        case .refused: "minus.circle"
        case .unavailable: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct AgentStateSymbol: View {
    let state: ConversationAgent.State
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible
    @InterfaceScaledMetric(relativeTo: .body) private var width: CGFloat = 24

    var body: some View {
        WorkingSymbol(systemName: symbol, tint: tint, isAnimating: state == .working && animates)
            .fontWeight(.semibold)
            .frame(width: width)
            .accessibilityLabel(state.title)
    }

    private var animates: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible, reduceMotion: reduceMotion)
    }

    private var symbol: String {
        switch state {
        case .working: "ellipsis"
        case .waiting: "hand.raised.fill"
        case .completed: "checkmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .removed: "minus.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .working: themeStore.theme.colors.accentTint
        case .waiting: .orange
        case .failed: .red
        case .completed, .interrupted, .unknown, .removed: .secondary
        }
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

private struct ConversationAgentDetail: View {
    let workspace: ChatWorkspaceModel
    let model: ConversationAgentsModel
    let agentID: String
    let onParentRequest: (String) async throws -> Void
    let onOpenConversation: (ConversationAgent) async throws -> Void
    let onAction: (ConversationAgent, ConversationAgentAction, String, UUID) async throws -> Void
    @State private var movesUnder = false
    @State private var promotes = false
    @State private var output: ConversationAgentOutput?
    @State private var outputGeneration: UInt64 = 0
    @State private var text = ""
    @State private var error: String?
    @State private var stopRequested = false
    @State private var opensConversation = false
    @State private var pendingAction: PendingAction?
    @State private var mutationID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private enum PendingAction: Equatable {
        case agent(ConversationAgentAction)
        case askParent
    }

    private var agent: ConversationAgent? { model.agent(for: agentID) }

    var body: some View {
        List {
            if let agent {
                Group {
                    Section {
                        header(agent)
                    } footer: {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else if stopRequested && (agent.state == .working || agent.state == .waiting) {
                            Label("Stop requested", systemImage: "stop.circle")
                        }
                    }
                    if agent.capabilities.message || agent.capabilities.continueWork {
                        Section { instructionField(agent) }
                    }
                    if agent.capabilities.inspect { Section { outputRows } }
                }
            } else {
                ContentUnavailableView("Agent Unavailable", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .navigationTitle(agent?.title ?? "Agent")
        .inlineNavigationTitle()
        .toolbar {
            if let agent {
                ToolbarItem(placement: .primaryAction) { actionsMenu(agent) }
            }
        }
        .sheet(isPresented: $movesUnder) {
            if let agent, let address = agent.address(localHostID: model.address.hostID) {
                AgentPlacementPicker(agent: address, workspace: workspace)
            }
        }
        .task(id: promotes) {
            guard promotes, let agent, let address = agent.address(localHostID: model.address.hostID) else { return }
            defer { promotes = false }
            do {
                try await workspace.moveAgent(address, under: nil)
                model.invalidate()
                await model.refresh()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: text) { mutationID = UUID() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadOutput()
        }
        .refreshable { await model.refresh(); await loadOutput() }
        .task(id: opensConversation) {
            guard opensConversation, let agent else { return }
            defer { opensConversation = false }
            do { try await onOpenConversation(agent) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: pendingAction) {
            guard let pendingAction, let agent else { return }
            defer { self.pendingAction = nil }
            do {
                guard case .agent(let action) = pendingAction else {
                    try await onParentRequest(agent.parentRequest)
                    return
                }
                try await onAction(agent, action, text, mutationID)
                try Task.checkCancellation()
                HapticService.shared.play(.success)
                if action == .stop { stopRequested = true }
                error = nil
                text = ""
                mutationID = UUID()
                model.invalidate()
                await model.refresh()
                await loadOutput()
            } catch {
                if !Task.isCancelled {
                    HapticService.shared.play(.error)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func header(_ agent: ConversationAgent) -> some View {
        HStack(spacing: 14) {
            AgentStateSymbol(state: agent.state)
                .scaledFont(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.intentState.map(\.title) ?? agent.state.title)
                    .scaledFont(.headline)
                Text(agent.model ?? agent.provider.displayName)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func instructionField(_ agent: ConversationAgent) -> some View {
        let action: ConversationAgentAction = agent.capabilities.message ? .message : .continue
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(agent.capabilities.message ? "Message" : "Continue with…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .disabled(pendingAction != nil)
            Button {
                pendingAction = .agent(action)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .disabled(isEmpty || pendingAction != nil)
            .accessibilityLabel(agent.capabilities.message ? "Send" : "Continue")
            .tooltip(agent.capabilities.message ? "Send" : "Continue")
        }
    }

    @ViewBuilder
    private var outputRows: some View {
        if let output {
            if output.truncated {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Earlier output not shown")
            }
            if output.messages.isEmpty {
                Text("No output yet").foregroundStyle(.secondary)
            }
            ForEach(Array(output.messages.enumerated()), id: \.offset) { _, message in
                let isPrompt = message.role == .user
                Text(verbatim: message.text)
                    .scaledFont(isPrompt ? .callout : .body)
                    .foregroundStyle(isPrompt ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func actionsMenu(_ agent: ConversationAgent) -> some View {
        AppMenu(trigger: .icon) {
            if agent.capabilities.openConversation {
                Button("Open Conversation", systemImage: "text.bubble") { opensConversation = true }
            }
            if agent.capabilities.askParent {
                Button("Ask in Chat", systemImage: "quote.bubble") { pendingAction = .askParent }
            }
            if agent.threadId != nil, agent.state != .removed {
                Divider()
                Button("Move to sidebar", systemImage: "sidebar.left") { promotes = true }
                Button("Move under…", systemImage: "person.2") { movesUnder = true }
            }
            if agent.capabilities.stop {
                Divider()
                Button("Stop Agent", systemImage: "stop.circle", role: .destructive) { pendingAction = .agent(.stop) }
            }
        } label: {
            Label("Agent actions", systemImage: "ellipsis")
        }
        .tooltip("Agent actions")
        .disabled(opensConversation || pendingAction != nil)
    }

    private func loadOutput() async {
        guard agent?.capabilities.inspect == true else { return }
        outputGeneration &+= 1
        let generation = outputGeneration
        do {
            let result = try await model.output(for: agentID)
            try Task.checkCancellation()
            guard generation == outputGeneration else { return }
            output = result
        } catch {
            if !Task.isCancelled && generation == outputGeneration { self.error = error.localizedDescription }
        }
    }
}
