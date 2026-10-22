import SwiftUI

struct ConversationPinRequest: Identifiable {
    enum Kind { case pin, rename }

    let kind: Kind
    let address: ConversationAddress

    var id: String { "\(kind)|\(address.id)" }
}

extension View {
    func conversationPinPrompt(_ request: Binding<ConversationPinRequest?>, workspace: ChatWorkspaceModel) -> some View {
        modifier(ConversationPinPrompt(request: request, workspace: workspace))
    }
}

private struct ConversationPinPrompt: ViewModifier {
    @Binding var request: ConversationPinRequest?
    let workspace: ChatWorkspaceModel
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, item: $request) { request in
                TextField("Pinned chat name", text: $name)
                    .onChange(of: name) { name = ConversationPinName.clamped(name) }
                Button(request.kind == .pin ? "Pin" : "Rename") { commit(request) }
                    .disabled(trimmedName.isEmpty)
                Button("Cancel", role: .cancel) { name = "" }
            } message: { request in
                Text(request.kind == .pin ? "Pinned chats need a name." : "Update the pinned chat name.")
            }
            .onChange(of: request?.id) {
                guard let request else { return }
                name = request.kind == .rename ? workspace.pinnedName(for: request.address) ?? "" : ""
            }
    }

    private var title: String {
        switch request?.kind {
        case .pin: "Name this pinned chat"
        case .rename: "Rename pinned chat"
        case nil: ""
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ request: ConversationPinRequest) {
        let name = trimmedName
        self.name = ""
        guard !name.isEmpty else { return }
        let previous = workspace.pinnedName(for: request.address)
        workspace.pin(request.address, name: name)
        if workspace.pinnedName(for: request.address) != previous {
            HapticService.shared.play(request.kind == .pin ? .toggleOn : .commit)
        }
    }
}
