import SwiftUI

struct EditingTextAttachment: Identifiable {
    let id = UUID()
    let attachmentID: UUID
    let text: String
    let draft: ComposerDraft
    let screen: ChatScreenModel
}

struct PastedTextEditor: View {
    @State var text: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .scaledFont(.body.monospaced())
                .padding()
                .accessibilityIdentifier("pasted-text-editor")
                .navigationTitle("Pasted Text")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(text); dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .attachmentViewerSize()
        .interactiveDismissDisabled()
    }
}

extension View {
    func attachmentViewerSize() -> some View {
        #if os(macOS)
        frame(minWidth: 480, idealWidth: 640, minHeight: 360, idealHeight: 480)
        #else
        presentationDetents([.large])
        #endif
    }
}
