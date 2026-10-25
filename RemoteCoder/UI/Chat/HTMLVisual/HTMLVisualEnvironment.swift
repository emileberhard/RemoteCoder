import OSLog
import SwiftUI

extension EnvironmentValues {
    @Entry var htmlVisualTheme: HTMLVisualTheme?
    @Entry var htmlVisualCaptureAllowed = true
}

extension View {
    func htmlVisualEnvironment() -> some View { modifier(HTMLVisualEnvironment()) }
}

private struct HTMLVisualEnvironment: ViewModifier {
    private static let logger = AppLogger(category: "HTMLVisual")
    @Environment(\.htmlVisualSource) private var source
    @Environment(\.self) private var environment
    @Environment(AppThemeStore.self) private var themeStore
    @InterfaceScaledMetric(relativeTo: .body) private var fontSize = TypeMetrics.bodyPointSize

    func body(content: Content) -> some View {
        let theme = HTMLVisualTheme(fontSize: fontSize, environment: environment, accent: themeStore.theme.colors.accentTint)
        content.environment(\.htmlVisualTheme, theme)
        .onChange(of: theme.isDark, initial: true) { _, dark in
            Self.logger.notice("html visual theme dark=\(dark) phase=\(String(describing: environment.scenePhase))")
        }
        .task(id: source.map { ObjectIdentifier($0.renderer) }) {
            if let source { await source.renderer.load() }
        }
    }
}

private extension HTMLVisualTheme {
    static let cssLocale = Locale(identifier: "en_US_POSIX")

    init(fontSize: Double, environment: EnvironmentValues, accent: Color) {
        self.init(fontSize: fontSize, text: Self.cssColor(.primary, in: environment),
            secondaryText: Self.cssColor(.secondary, in: environment),
            background: Self.cssColor(.appSystemBackground, in: environment),
            surface: Self.cssColor(.appSecondarySystemBackground, in: environment),
            accent: Self.cssColor(accent, in: environment), isDark: environment.colorScheme == .dark)
    }

    static func cssColor(_ color: Color, in environment: EnvironmentValues) -> String {
        let resolved = color.resolve(in: environment)
        let channel = { (value: Float) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "rgba(%ld,%ld,%ld,%.4f)", locale: cssLocale, channel(resolved.red),
            channel(resolved.green), channel(resolved.blue), max(0, min(1, resolved.opacity)))
    }
}
