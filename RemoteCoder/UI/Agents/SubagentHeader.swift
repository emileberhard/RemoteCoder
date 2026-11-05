import SwiftUI

struct SubagentHeader: View {
    let context: SubagentContext

    var body: some View {
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
    let canStop: Bool
    let hasQuestion: Bool
    let onViewQuestion: () -> Void
    let onAskParent: (() -> Void)?
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("Read-only subagent", systemImage: "eye")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hasQuestion {
                Button("View Question", action: onViewQuestion)
            }
            if let onAskParent {
                Button("Ask Parent", action: onAskParent)
            }
            if canStop {
                Button("Stop", role: .destructive, action: onStop)
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
