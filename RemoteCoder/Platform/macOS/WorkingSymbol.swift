#if os(macOS)
import SwiftUI

struct WorkingSymbol: View {
    let systemName: String
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(tint)
    }
}
#endif
