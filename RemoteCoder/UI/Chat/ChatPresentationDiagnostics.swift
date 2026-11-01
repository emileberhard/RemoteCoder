import SwiftUI

extension View {
    func chatPresentationDiagnostics(_ name: String) -> some View {
        modifier(ChatPresentationObservation(name: name))
    }
}

private struct ChatPresentationObservation: ViewModifier {
    let name: String
    #if os(iOS)
    @Environment(\.chatLayoutRecorder) private var recorder
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onAppear { recorder?.presentation(name, isPresented: true) }
            .onDisappear { recorder?.presentation(name, isPresented: false) }
        #else
        content
        #endif
    }
}
