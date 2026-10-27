import SwiftUI
import UIKit

struct HTMLVisualOccurrenceVisibility: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        } else {
            content.onAppear { isVisible = true }.onDisappear { isVisible = false }
        }
    }
}
