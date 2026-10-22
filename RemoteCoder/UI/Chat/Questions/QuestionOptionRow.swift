import SwiftUI

/// One selectable answer. State is carried by fill, stroke and glyph together,
/// never by colour alone.
struct QuestionOptionRow: View {
    let title: String
    let isSelected: Bool
    let isSuggested: Bool
    let action: () -> Void

    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        label
                        if isSuggested { suggestedTag }
                    }
                } else {
                    label
                    if isSuggested { suggestedTag }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(themeStore.theme.colors.accentTint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(ControlMetrics.rowInsets)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
            .themedSurface(cornerRadius: 12, fill: isSelected ? .selectedOption : .tint,
                           stroke: isSelected ? .accent(lineWidth: contrast == .increased ? 1.5 : 1) : .standard)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: isSelected ? .buttonPress : nil, pressedScale: 0.98))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        Text(title)
            .scaledFont(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var suggestedTag: some View {
        Text("Suggested")
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(themeStore.theme.tintedSurfaceStroke(for: colorScheme)))
    }
}
