import SwiftUI

struct ConversationProviderMark: View {
    static let symbol = "point.3.connected.trianglepath.dotted"
    let route: RouterRoute

    var body: some View {
        Image(systemName: Self.symbol)
            .accessibilityLabel("\(route.title) inference override")
    }
}

struct ConversationProviderPicker: View {
    let address: ConversationAddress
    let directory: RouterAccountDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = directory.conversationProviders[address.hostID] {
                    let selected = snapshot.routes[address.threadID]
                    choice("Use Default", route: nil, selected: selected)
                    ForEach(snapshot.options(for: address.threadID), id: \.self) { route in
                        choice(route.title, route: route, selected: selected)
                    }
                } else {
                    Text("Provider choices are unavailable.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Inference Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            #if os(macOS)
            .frame(minWidth: 320, minHeight: 250)
            #endif
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func choice(_ title: String, route: RouterRoute?, selected: RouterRoute?) -> some View {
        Button {
            guard route != selected else { dismiss(); return }
            isSaving = true
            error = nil
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    try await directory.setConversationProvider(route, for: address)
                    dismiss()
                } catch is CancellationError {
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selected == route {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(selected == route ? .isSelected : [])
        .disabled(isSaving)
    }
}
