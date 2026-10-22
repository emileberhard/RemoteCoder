import SwiftUI

// RemoteCoder's single Liquid Glass entry point. Every glass surface and iOS
// glass button takes the active theme's translucent accent tint and hairline
// stroke from here, so a new component cannot ship clear, untinted glass by accident.
// The tint math is private to this file and `scripts/lint-glass` rejects raw
// `.glassEffect(` and `.buttonStyle(.glass…)` anywhere else in the app.
//
// HIG: Liquid Glass has no inherent color; tint is meant to be sparing and
// low-contrast so content underneath still shows through. Tune the shared
// mix and opacities in `glassTint`/`glassTintOpacity` below, never at a call site.

extension View {
    /// Theme-tinted Liquid Glass behind this view in `shape`, with the theme's
    /// hairline stroke. `interactive` adds the system press reaction for
    /// controls that are not native buttons.
    func appGlass<S: Shape>(
        _ role: AppTheme.GlassRole,
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(AppGlassModifier(role: role, shape: shape, interactive: interactive))
    }

    func appContentSurface<S: InsettableShape>(
        _ role: AppTheme.GlassRole,
        in shape: S
    ) -> some View {
        modifier(AppContentSurfaceModifier(role: role, shape: shape))
    }
}

extension PrimitiveButtonStyle where Self == AppGlassButtonStyle {
    /// The glass button: on iOS, system glass chrome filled with the theme's
    /// translucent control tint; on the Mac, untinted system glass, because the
    /// accent belongs to primary actions. Use instead of `.glass` and
    /// `.glassProminent`.
    static var appGlass: AppGlassButtonStyle { AppGlassButtonStyle(feedback: .press) }

    /// Use only when the action already owns a semantic acknowledgement.
    static var appGlassActionFeedback: AppGlassButtonStyle { AppGlassButtonStyle(feedback: .actionOwned) }
}

struct AppGlassButtonStyle: PrimitiveButtonStyle {
    enum Feedback { case press, actionOwned }
    let feedback: Feedback
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            if feedback == .press { HapticService.shared.play(.buttonPress) }
            configuration.trigger()
        } label: {
            configuration.label
        }
        #if os(macOS)
        .buttonStyle(.glass)
        #else
        .buttonStyle(.glassProminent)
        .tint(themeStore.theme.controlGlassTint(for: colorScheme))
        #endif
    }
}

private struct AppGlassModifier<S: Shape>: ViewModifier {
    let role: AppTheme.GlassRole
    let shape: S
    let interactive: Bool
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = themeStore.theme
        content
            .glassEffect(theme.glass(role, colorScheme: colorScheme, interactive: interactive), in: shape)
            .overlay {
                shape.stroke(
                    theme.glassStroke(for: role, colorScheme: colorScheme),
                    lineWidth: role == .selected ? 1 : 0.6
                )
            }
    }
}

private struct AppContentSurfaceModifier<S: InsettableShape>: ViewModifier {
    let role: AppTheme.GlassRole
    let shape: S
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = themeStore.theme
        content
            .background {
                shape.fill(theme.contentSurfaceFill(for: role, colorScheme: colorScheme))
            }
            .overlay {
                shape.strokeBorder(
                    theme.glassStroke(for: role, colorScheme: colorScheme),
                    lineWidth: role == .selected ? 1 : 0.5
                )
            }
    }
}

private extension AppTheme {
    func glass(_ role: GlassRole, colorScheme: ColorScheme, interactive: Bool) -> Glass {
        let material = Glass.regular.tint(glassTint(for: role, colorScheme: colorScheme))
        return interactive ? material.interactive() : material
    }

    func controlGlassTint(for colorScheme: ColorScheme) -> Color {
        glassTint(for: .standard, colorScheme: colorScheme)
    }

    func glassStroke(for role: GlassRole, colorScheme: ColorScheme) -> Color {
        switch role {
        case .standard:
            return Color.primary.opacity(colorScheme == .light ? 0.12 : 0.18)
        case .selected:
            return colors.accentTint.opacity(colorScheme == .light ? 0.55 : 0.70)
        }
    }

    /// The accent pulled most of the way toward the scheme's base (black in
    /// dark, white in light) before it meets the glass. A muted, darker tint at
    /// a moderate opacity settles the glass and keeps text contrast, where the
    /// pure accent at the same strength would read as a colored fill. The
    /// selected role keeps more of the accent: selection is shown by the row
    /// taking on the theme color, the way system sidebars fill the current
    /// item with the accent, rather than by a glyph.
    private func glassTint(for role: GlassRole, colorScheme: ColorScheme) -> Color {
        glassTintBase(for: role, colorScheme: colorScheme)
            .opacity(glassTintOpacity(for: role, colorScheme: colorScheme))
    }

    func contentSurfaceFill(for role: GlassRole, colorScheme: ColorScheme) -> Color {
        Color.appSystemBackground.mix(
            with: glassTintBase(for: role, colorScheme: colorScheme),
            by: glassTintOpacity(for: role, colorScheme: colorScheme)
        )
    }

    private func glassTintBase(for role: GlassRole, colorScheme: ColorScheme) -> Color {
        let base: Color = colorScheme == .light ? .white : .black
        let towardBase: Double = switch role {
        case .standard: colorScheme == .light ? 0.45 : 0.55
        case .selected: colorScheme == .light ? 0.25 : 0.30
        }
        return colors.accentTint
            .mix(with: base, by: towardBase)
    }

    private func glassTintOpacity(for role: GlassRole, colorScheme: ColorScheme) -> Double {
        switch role {
        case .standard:
            return colorScheme == .light ? 0.66 : 0.70
        case .selected:
            return colorScheme == .light ? 0.76 : 0.80
        }
    }
}
