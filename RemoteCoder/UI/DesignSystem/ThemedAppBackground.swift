import SwiftUI

struct ThemedAppBackground: View {
    var body: some View {
        Color.appSystemBackground
            .ignoresSafeArea()
    }
}

struct ThemedSheetBackground: View {
    var body: some View {
        ThemedSheetLayers()
            .ignoresSafeArea()
    }
}

struct ThemedSheetBottomBarBackground: View {
    private let fadeHeight: CGFloat = 28

    var body: some View {
        ThemedSheetLayers(fadeHeight: fadeHeight)
            .padding(.top, -fadeHeight)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
    }
}

private struct ThemedSheetLayers: View {
    var fadeHeight: CGFloat?
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let fadeHeight {
            GeometryReader { geometry in
                let stop = min(fadeHeight / max(geometry.size.height, 1), 1)
                ZStack {
                    gradient(Color.appSystemBackground, stop: stop)
                    gradient(themeStore.theme.sheetBackgroundTint(for: colorScheme), stop: stop)
                }
            }
        } else {
            ZStack {
                Color.appSystemBackground
                themeStore.theme.sheetBackgroundTint(for: colorScheme)
            }
        }
    }

    private func gradient(_ color: Color, stop: CGFloat) -> some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: color, location: stop),
                               .init(color: color, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}
