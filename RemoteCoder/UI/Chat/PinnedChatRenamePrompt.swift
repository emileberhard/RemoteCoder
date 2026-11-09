import SwiftUI

extension View {
    func pinnedChatRenamePrompt(_ address: Binding<ConversationAddress?>, workspace: ChatWorkspaceModel) -> some View {
        modifier(PinnedChatRenamePrompt(address: address, workspace: workspace))
    }
}

private struct PinnedChatRenamePrompt: ViewModifier {
    @Binding var address: ConversationAddress?
    let workspace: ChatWorkspaceModel
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename pinned chat", item: $address) { address in
                TextField("Pinned chat name", text: $name)
                    .onChange(of: name) { name = ConversationPinName.clamped(name) }
                Button("Rename") { commit(address) }
                    .disabled(trimmedName.isEmpty)
                Button("Cancel", role: .cancel) { name = "" }
            } message: { _ in
                Text("Update the pinned chat name.")
            }
            .onChange(of: address) {
                guard let address else { return }
                name = workspace.pinnedName(for: address) ?? ""
            }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ address: ConversationAddress) {
        let name = trimmedName
        self.name = ""
        guard !name.isEmpty else { return }
        let previous = workspace.pinnedName(for: address)
        workspace.pin(address, name: name)
        if workspace.pinnedName(for: address) != previous {
            HapticService.shared.play(.commit)
        }
    }
}
