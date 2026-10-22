#if os(macOS)
import SwiftUI

extension View {
    func tooltip(_ text: LocalizedStringKey) -> some View { help(text) }
}
#endif
