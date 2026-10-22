import SwiftUI

enum ThemedSurfaceFill {
    case attachment
    case userBubble
    case tint
    case base
    case selectedOption
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
        let layers = fillLayers
        content
            .background {
                ZStack {
                    ForEach(layers.indices, id: \.self) { shape.fill(layers[$0]) }
                }
            }
            .overlay {
                switch stroke {
                case .none:
                    EmptyView()
                case .standard:
                    shape.strokeBorder(themeStore.theme.tintedSurfaceStroke(for: colorScheme), lineWidth: 0.5)
                case .accent(let lineWidth):
                    shape.strokeBorder(themeStore.theme.colors.accentTint, lineWidth: lineWidth)
                }
            }
    }

    private var fillLayers: [Color] {
        let theme = themeStore.theme
        switch fill {
        case .attachment: return [theme.tintedSurfaceBase(for: colorScheme), theme.messageAttachmentTint(for: colorScheme)]
        case .userBubble: return [theme.userBubbleBase, theme.userBubbleTint(for: colorScheme)]
        case .tint: return [theme.messageAttachmentTint(for: colorScheme)]
        case .base: return [theme.tintedSurfaceBase(for: colorScheme)]
        case .selectedOption: return [theme.selectedOptionTint(for: colorScheme)]
        }
    }
}

extension View {
    func themedSurface(cornerRadius: CGFloat, fill: ThemedSurfaceFill = .attachment,
                       stroke: ThemedSurfaceStroke = .standard) -> some View {
        modifier(ThemedSurface(cornerRadius: cornerRadius, fill: fill, stroke: stroke))
    }
}
