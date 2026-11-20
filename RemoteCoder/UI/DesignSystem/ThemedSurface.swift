import SwiftUI

enum ThemedSurfaceFill {
    case elevated
    case tinted
    case subtle
    case selected
}

enum ThemedSurfaceStroke {
    case none
    case standard
    case accent(lineWidth: CGFloat)
}

private struct ThemedSurface: ViewModifier {
    let cornerRadius: CGFloat
    let fill: ThemedSurfaceFill
    let stroke: ThemedSurfaceStroke
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background { shape.fill(fillColor) }
            .overlay {
                switch stroke {
                case .none:
                    EmptyView()
                case .standard:
                    shape.strokeBorder(Color.appHairline, lineWidth: 0.5)
                case .accent(let lineWidth):
                    shape.strokeBorder(themeStore.theme.colors.accentTint, lineWidth: lineWidth)
                }
            }
    }

    private var fillColor: Color {
        switch fill {
        case .elevated: .appSecondarySystemBackground
        case .tinted: themeStore.theme.surfaceTint(for: colorScheme)
        case .subtle: .appSubtleFill
        case .selected: .appSelectedFill
        }
    }
}

extension View {
    func themedSurface(cornerRadius: CGFloat, fill: ThemedSurfaceFill = .elevated,
                       stroke: ThemedSurfaceStroke = .standard) -> some View {
        modifier(ThemedSurface(cornerRadius: cornerRadius, fill: fill, stroke: stroke))
    }
}
