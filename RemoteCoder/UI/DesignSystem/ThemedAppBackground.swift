import SwiftUI

struct ThemedAppBackground: View {
    var body: some View {
        Color.appSystemBackground
            .ignoresSafeArea()
    }
}

struct DrawerBackground: View {
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    fileprivate static func color(accent: Color, colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark { return .black }
        return Color.appSystemBackground.mix(with: .appSecondarySystemBackground, by: 0.70)
            .mix(with: accent, by: 0.035)
    }

    var body: some View {
        Self.color(accent: themeStore.theme.colors.accentTint, colorScheme: colorScheme)
            .ignoresSafeArea()
    }
}

struct DrawerBottomBarBackground: View {
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = DrawerBackground.color(accent: themeStore.theme.colors.accentTint, colorScheme: colorScheme)
        VStack(spacing: 0) {
            LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
            color
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}
