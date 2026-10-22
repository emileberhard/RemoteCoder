import SwiftUI

struct ChatSidebarContainer<Detail: View, Sidebar: View>: View {
    let isPersistent: Bool
    @Binding var isOpen: Bool
    let onBeginOpening: () -> Void
    @ViewBuilder let detail: Detail
    @ViewBuilder let sidebar: Sidebar

    @Environment(\.interfaceScale) private var scale

    var body: some View {
        #if os(iOS)
        if isPersistent {
            splitView
        } else {
            NavigationStack {
                ConversationDrawer(isOpen: $isOpen, onBeginOpening: onBeginOpening) {
                    detail
                } sidebar: {
                    sidebar
                }
            }
        }
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260 * scale, ideal: 300 * scale, max: 380 * scale)
        } detail: {
            NavigationStack { detail }
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isOpen ? .all : .detailOnly },
            set: { isOpen = $0 != .detailOnly }
        )
    }
}
