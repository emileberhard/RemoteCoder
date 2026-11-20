import SwiftUI

// RemoteCoder's single Liquid Glass entry point. Every app glass surface uses
// the same material and tint. `scripts/lint-glass` guards the entry point.
//
// Glass uses the shared surface tint from AppTheme.

extension View {
    /// Liquid Glass behind this view in `shape`, with a
    /// hairline stroke. `interactive` adds the system press reaction for
    /// controls that are not native buttons.
    func appGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(AppGlassModifier(shape: shape, interactive: interactive))
    }

    func appContentSurface<S: InsettableShape>(
        _ role: AppContentSurfaceRole,
        in shape: S
    ) -> some View {
        modifier(AppContentSurfaceModifier(role: role, shape: shape))
    }
}

private struct AppGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let material = Glass.regular.tint(themeStore.theme.surfaceTint(for: colorScheme))
        content
            .glassEffect(interactive ? material.interactive() : material, in: shape)
            .overlay {
                shape.stroke(Color.primary.opacity(colorScheme == .light ? 0.12 : 0.18), lineWidth: 0.6)
            }
    }
}

enum AppContentSurfaceRole {
    case standard
    case selected
}

private struct AppContentSurfaceModifier<S: InsettableShape>: ViewModifier {
    let role: AppContentSurfaceRole
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            shape.fill(role == .selected ? Color.appSelectedFill : Color.appSubtleFill)
                .overlay {
                    if role == .selected {
                        shape.strokeBorder(
                            Color.primary.opacity(contrast == .increased ? 0.65 : 0.26),
                            lineWidth: contrast == .increased ? 1.5 : 1
                        )
                    }
                }
        }
    }
}
