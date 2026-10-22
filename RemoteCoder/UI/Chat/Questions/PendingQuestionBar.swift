import SwiftUI

/// Reachability for an unanswered model question: one row inside the composer
/// that scrolls to the card or opens it in a sheet. Content inside the
/// composer's glass, never a second glass layer.
struct PendingQuestionBar: View {
    let prompt: QuestionPrompt
    let action: () -> Void

    @Environment(AppThemeStore.self) private var themeStore

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(themeStore.theme.colors.accentTint)
                Text("Codex has a question")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .scaledFont(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.99))
        .themedSurface(cornerRadius: 20, fill: .tint, stroke: .none)
        .accessibilityLabel("Codex has a question")
        .accessibilityValue(prompt.questions.first?.title ?? "")
        .accessibilityHint("Shows the question")
        .accessibilityIdentifier("pending-question-bar")
        .contextMenuPreviewShape(RoundedRectangle(cornerRadius: 20))
        .contextMenu {
            Button("Answer question", systemImage: "questionmark.bubble", action: action)
        } preview: {
            ControlPeekPreview(symbol: "questionmark.bubble", title: "Pending question",
                               subtitle: "Review before answering", detail: prompt.questions.first?.title ?? "")
        }
    }
}
