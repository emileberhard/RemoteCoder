import SwiftUI

extension View {
    func noAutocapitalization() -> some View {
        textInputAutocapitalization(.never)
    }

    func wordAutocapitalization() -> some View {
        textInputAutocapitalization(.words)
    }

    func numericKeyboard() -> some View {
        keyboardType(.numberPad)
    }

    func drillDownPickerStyle() -> some View {
        pickerStyle(.navigationLink)
    }

    func appFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        fullScreenCover(item: item, content: content)
    }

    func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        contentShape(.contextMenuPreview, shape)
    }
}
