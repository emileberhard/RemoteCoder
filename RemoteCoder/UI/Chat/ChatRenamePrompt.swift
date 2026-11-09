import SwiftUI

struct ChatRenameRequest: Identifiable, Equatable {
    let address: ConversationAddress
    let title: String?
    var id: ConversationAddress { address }
}

extension View {
    func chatRenamePrompt(_ request: Binding<ChatRenameRequest?>, workspace: ChatWorkspaceModel) -> some View {
        modifier(ChatRenamePrompt(request: request, workspace: workspace))
    }
}

private struct ChatRenamePrompt: ViewModifier {
    @Binding var request: ChatRenameRequest?
    let workspace: ChatWorkspaceModel
    @State private var name = ""
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", item: $request) { request in
                TextField("Chat name", text: $name)
                    .onChange(of: name) {
                        if !workspace.supportsIndependentNames(request.address) { name = ConversationPinName.clamped(name) }
                    }
                Button("Rename") { commit(request.address) }
                    .disabled(trimmedName.isEmpty)
                Button("Cancel", role: .cancel) { name = "" }
            }
            .onChange(of: request) {
                guard let request else { return }
                name = request.title ?? ""
            }
            .alert("Could not rename chat", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ address: ConversationAddress) {
        let name = trimmedName
        self.name = ""
        guard !name.isEmpty else { return }
        workspace.rename(address, name: name) { failure = $0 }
    }
}
