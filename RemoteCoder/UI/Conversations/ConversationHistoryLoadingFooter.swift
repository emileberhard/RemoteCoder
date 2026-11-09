import SwiftUI

struct ConversationHistoryLoadingFooter: View {
    let workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let states: [ConversationSidebarHostState]
    let open: (ConversationAddress) -> ChatWorkspaceModel.ConversationSwitchOutcome
    @State private var loading: Task<Void, Never>?

    var body: some View {
        let older = states.filter(\.canLoadMore)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(states) { state in
                let pins = state.unloadedPins.filter { pin in
                    ConversationSidebarProjection.matches(title: pin.title, workingDirectory: "",
                        hostName: state.showsHostLabel ? state.hostName : nil, query: window.drawerQuery)
                }
                if !pins.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.showsHostLabel { Text(state.hostName).foregroundStyle(.secondary) }
                        ForEach(pins.prefix(16)) { pin in
                            Button {
                                _ = open(ConversationAddress(hostID: state.hostID, threadID: pin.id))
                            } label: {
                                Label(pin.title ?? "Unknown title", systemImage: "pin")
                            }
                        }
                        if pins.count > 16 {
                            Text("\(pins.count - 16) more pinned chats aren't loaded").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !older.isEmpty {
                Button(window.drawerQuery.isEmpty ? "Load older chats" : "Search more history") {
                    loading?.cancel()
                    loading = Task { await workspace.loadOlderHistory(in: window) }
                }
                .disabled(older.allSatisfy(\.isLoading))
            }
        }
        .scaledFont(.footnote)
        .onDisappear { loading?.cancel(); loading = nil }
    }
}
