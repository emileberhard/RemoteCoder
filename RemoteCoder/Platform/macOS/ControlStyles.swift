#if os(macOS)
import SwiftUI

extension View {
    func noAutocapitalization() -> some View { self }

    func wordAutocapitalization() -> some View { self }

    func numericKeyboard() -> some View { self }

    func drillDownPickerStyle() -> some View {
        pickerStyle(.menu)
    }

    func appFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, content: content)
    }

    func contextMenuPreviewShape(_ shape: some Shape) -> some View { self }
}
#endif
