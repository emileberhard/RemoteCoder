import SwiftUI

struct ChatSidebarContainer<Detail: View, Sidebar: View>: View {
    let isPersistent: Bool
    let presentation: DrawerPresentation
    @ViewBuilder let detail: Detail
    @ViewBuilder let sidebar: Sidebar

    @Environment(\.interfaceScale) private var scale

    var body: some View {
        #if os(iOS)
        if isPersistent {
            splitView
        } else {
            NavigationStack {
                ConversationDrawer(presentation: presentation) {
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
            get: { presentation.isOpen ? .all : .detailOnly },
            set: { presentation.isOpen = $0 != .detailOnly }
        )
    }
}
