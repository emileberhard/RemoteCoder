#if os(macOS)
import SwiftUI

enum TypeMetrics {
    static let bodyPointSize: CGFloat = 13
    static let code = Font.system(.callout, design: .monospaced)

    static func symbol(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: max(10, (size * 13 / 17).rounded()), weight: weight)
    }
}
#endif
