import SwiftUI

struct DrawerSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isFirst: Bool
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, isFirst ? 6 : 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct DrawerMoreButton: View {
    let title: String
    let action: () -> Void
    @Environment(AppThemeStore.self) private var themeStore
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 18

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .frame(width: iconWidth, alignment: .center)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(themeStore.theme.colors.accentTint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .padding(.vertical, -6)
        .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 0.99, pressedOpacity: 0.8))
    }
}
