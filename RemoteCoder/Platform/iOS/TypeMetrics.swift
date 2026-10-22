import SwiftUI

enum TypeMetrics {
    static let bodyPointSize: CGFloat = 17
    static let code = Font.system(size: 13, design: .monospaced)

    static func symbol(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight)
    }
}
