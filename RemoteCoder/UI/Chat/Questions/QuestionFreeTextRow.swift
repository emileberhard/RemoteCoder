import SwiftUI

/// The always-available free-text answer. On an options question it starts as
/// a "Something else…" row and expands into the field; a free-text-only
/// question shows the field directly.
struct QuestionFreeTextRow: View {
    @Binding var text: String
    let isExpanded: Bool
    let isLastQuestion: Bool
    let focus: FocusState<Bool>.Binding
    let accessibilityIdentifier: String
    let onExpand: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        if isExpanded {
            TextField("Your answer", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .scaledFont(.body)
                .submitLabel(isLastQuestion ? .done : .next)
                .onSubmit(onSubmit)
                .focused(focus)
                .padding(ControlMetrics.rowInsets)
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
                .themedSurface(cornerRadius: 12, fill: .base, stroke: focus.wrappedValue ? .accent(lineWidth: 1) : .standard)
                .accessibilityLabel("Your answer")
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    Text("Something else…")
                        .scaledFont(.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "pencil.line")
                        .scaledFont(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(ControlMetrics.rowInsets)
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
                .themedSurface(cornerRadius: 12, fill: .tint)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.98))
            .accessibilityHint("Type your own answer")
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
