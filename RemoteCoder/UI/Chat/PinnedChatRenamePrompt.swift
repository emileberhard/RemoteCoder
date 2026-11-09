import SwiftUI

extension View {
    func pinnedChatRenamePrompt(_ address: Binding<ConversationAddress?>, workspace: ChatWorkspaceModel,
                                currentTitle: @escaping (ConversationAddress) -> String? = { _ in nil }) -> some View {
        modifier(PinnedChatRenamePrompt(address: address, workspace: workspace, currentTitle: currentTitle))
    }
}

private struct PinnedChatRenamePrompt: ViewModifier {
    @Binding var address: ConversationAddress?
    let workspace: ChatWorkspaceModel
    let currentTitle: (ConversationAddress) -> String?
    @State private var name = ""
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", item: $address) { address in
                TextField("Chat name", text: $name)
                    .onChange(of: name) {
                        if !workspace.supportsIndependentNames(address) { name = ConversationPinName.clamped(name) }
                    }
                Button("Rename") { commit(address) }
                    .disabled(trimmedName.isEmpty)
                Button("Cancel", role: .cancel) { name = "" }
            }
            .onChange(of: address) {
                guard let address else { return }
                name = workspace.conversationTitle(address) ?? currentTitle(address) ?? ""
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
        HapticService.shared.play(.commit)
    }
}
