#if os(macOS)
import AppKit
import SwiftUI

extension Color {
    static var appLabel: Color { Color(nsColor: .labelColor) }
    static var appSystemBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var appSecondarySystemBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var appTertiarySystemBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var appSystemGray3: Color { Color(nsColor: .tertiaryLabelColor) }
}
#endif
