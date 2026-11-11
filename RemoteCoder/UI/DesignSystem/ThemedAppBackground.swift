import SwiftUI

struct ThemedAppBackground: View {
    var body: some View {
        Color.appSystemBackground
            .ignoresSafeArea()
    }
}

struct ThemedSheetBackground: View {
    var body: some View {
        ThemedSheetLayers { color in
            color
        }
        .ignoresSafeArea()
    }
}

struct ThemedSheetBottomBarBackground: View {
    private let fadeHeight: CGFloat = 28

    var body: some View {
        ThemedSheetLayers { color in
            VStack(spacing: 0) {
                LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
                color
            }
        }
        .padding(.top, -fadeHeight)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}

private struct ThemedSheetLayers<Layer: View>: View {
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    private let layer: (Color) -> Layer

    init(@ViewBuilder layer: @escaping (Color) -> Layer) {
        self.layer = layer
    }

    var body: some View {
        ZStack {
            layer(Color.appSystemBackground)
            layer(themeStore.theme.sheetBackgroundTint(for: colorScheme))
        }
    }
}
