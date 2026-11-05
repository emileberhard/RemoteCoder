import SwiftUI

struct ConversationStatusPills: View {
    let changes: ChangeSummaryModel?
    let agents: ConversationAgentsModel?
    let workspace: ChatWorkspaceModel
    @Binding var showsAgents: Bool
    let onReviewChanges: () -> Void
    let onOpenAgent: (ConversationAddress) -> Void
    @InterfaceScaledMetric(relativeTo: .body) private var rosterGap: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let changes, let content = changes.content {
                ChangesPill(changes: changes, content: content, action: onReviewChanges)
                    .transition(pillTransition)
            }
            if let agents {
                SubagentsPill(roster: agents.roster, isExpanded: showsAgents) { showsAgents.toggle() }
                    .layoutPriority(1)
                    .transition(pillTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if showsAgents, let agents {
                let gap = rosterGap
                AgentRoster(model: agents, workspace: workspace, onOpen: onOpenAgent)
                    .padding(.horizontal, 12)
                    .alignmentGuide(.top) { $0[.bottom] + gap }
                    .transition(rosterTransition)
            }
        }
        .animation(.smooth, value: changes?.content)
        .animation(.smooth, value: agents != nil)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.9), value: showsAgents)
    }

    private var pillTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
    }

    private var rosterTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.97, anchor: .bottom).combined(with: .offset(y: 8)).combined(with: .opacity)
    }
}

struct StatusPill<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .appGlass(.standard, in: .capsule)
                .padding(.vertical, StatusPillShape.hitMargin)
                .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.97))
        .contextMenuPreviewShape(StatusPillShape())
    }
}

private struct StatusPillShape: Shape {
    static let hitMargin: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        Capsule().path(in: rect.insetBy(dx: 0, dy: Self.hitMargin))
    }
}

struct ChangesPill: View {
    @Bindable var changes: ChangeSummaryModel
    let content: ChangesPillContent
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StatusPill(action: action) { face }
            .contextMenu {
                if changes.offersViews {
                    Button("Start From Now", systemImage: ChangesView.sinceSymbol, action: changes.countFromNow)
                    Section {
                        Picker("Compare", selection: $changes.selectedView) {
                            if content.view != .standard && content.view != .lastTurn {
                                Label(content.label ?? content.view.title, systemImage: content.view.systemImage)
                                    .tag(content.view)
                            }
                            Label(ChangesView.standard.title, systemImage: ChangesView.standard.systemImage)
                                .tag(ChangesView.standard)
                            Label(ChangesView.lastTurn.title, systemImage: ChangesView.lastTurn.systemImage)
                                .tag(ChangesView.lastTurn)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .accessibilityHint("Shows changes")
            .accessibilityIdentifier("review-changes")
    }

    private var face: some View {
        ViewThatFits(in: .horizontal) {
            counts(compact: false)
            counts(compact: true)
        }
        .monospacedDigit()
        .contentTransition(reduceMotion ? .identity : .numericText())
    }

    private func counts(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if let label = content.label {
                Text(label).foregroundStyle(.secondary)
            }
            switch content.count {
            case .known(let totals):
                FileCount(files: totals.files)
                if let lines = totals.lines {
                    DiffCounts(additions: lines.additions, deletions: lines.deletions, compact: compact)
                }
            case .unknown:
                EmptyView()
            case .startMissing:
                Text("Start Not Found")
            }
        }
        .lineLimit(1)
    }
}
