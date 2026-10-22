import SwiftUI

struct ThemedAppBackground: View {
    var body: some View {
        Color.appSystemBackground
            .ignoresSafeArea()
    }
}

struct ThemedSheetBackground: View {
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.appSystemBackground

            themeStore.theme.sheetBackgroundTint(for: colorScheme)
        }
        .ignoresSafeArea()
    }
}
