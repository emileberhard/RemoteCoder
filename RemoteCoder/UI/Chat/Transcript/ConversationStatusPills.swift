import SwiftUI

struct ConversationStatusPills: View {
    let changes: ChangeSummaryModel?
    let agents: ConversationAgentsModel?
    let onReviewChanges: () -> Void
    let onShowAgents: (ConversationAgentsModel) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let totals = changes?.totals {
                ChangesPill(totals: totals, action: onReviewChanges)
                    .transition(pillTransition)
            }
            if let agents {
                SubagentsPill(agents: agents, recent: agents.summary?.recent ?? 0) { onShowAgents(agents) }
                    .transition(pillTransition)
            }
        }
        .animation(.smooth, value: changes?.totals)
        .animation(.smooth, value: agents != nil)
    }

    private var pillTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
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
                .padding(.vertical, 8)
                .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.97))
    }
}

struct ChangesPill: View {
    let totals: ChangeTotals
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StatusPill(action: action) {
            HStack(spacing: 6) {
                FileCount(files: totals.files)
                if let lines = totals.lines {
                    DiffCounts(additions: lines.additions, deletions: lines.deletions)
                }
            }
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .accessibilityHint("Shows changes")
        .accessibilityIdentifier("review-changes")
    }
}
