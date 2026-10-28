import Foundation

@MainActor
struct ConversationHistoryActions {
    let open: (ConversationAddress) -> ChatWorkspaceModel.ConversationSwitchOutcome
    let pin: (ConversationSidebarRow) -> Void
    let rename: (ConversationSidebarRow) -> Void
    let regenerateName: (ConversationAddress) -> Void
    let unpin: (ConversationAddress) -> Void
    let fork: (ConversationAddress) -> Void
    let moveUnder: (ConversationAddress) -> Void
    let markRead: ([ConversationAddress]) -> Void
    let markUnread: (ConversationAddress) -> Void
    let settle: ([ConversationAddress]) -> Void
    let unsettle: ([ConversationAddress]) -> Void
    let openDraft: (UnsentDraftAddress) -> Void
    let discardDraft: (UnsentDraftAddress) -> Void
    let startNew: (UUID) -> Void
    let showSettings: () -> Void
    let focusComposer: () -> Void

    func rowMenuItems(for row: ConversationSidebarRow) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        if row.isPinned {
            items.append(ContextMenuItem(title: "Rename", systemImage: "pencil") { rename(row) })
            items.append(ContextMenuItem(title: "Unpin", systemImage: "pin.slash") { unpin(row.address) })
        } else {
            items.append(ContextMenuItem(title: "Pin", systemImage: "pin") { pin(row) })
            items.append(ContextMenuItem(title: "Regenerate Name", systemImage: "wand.and.sparkles") { regenerateName(row.address) })
        }
        items.append(ContextMenuItem(title: "Move under…", systemImage: "person.2") { moveUnder(row.address) })
        items.append(readToggle(for: row))
        items.append(ContextMenuItem(title: "Fork", systemImage: "arrow.triangle.branch") { fork(row.address) })
        if let toggle = settlementToggle(for: row) { items.append(toggle) }
        if let link = row.address.codexDesktopLink {
            items.append(ContextMenuItem(title: "Copy link", systemImage: "link") { HapticService.shared.copy(link) })
        } else {
            let threadID = row.address.threadID
            items.append(ContextMenuItem(title: "Copy thread ID", systemImage: "doc.on.doc") { HapticService.shared.copy(threadID) })
        }
        return items
    }

    func settlementToggle(for row: ConversationSidebarRow) -> ContextMenuItem? {
        if row.isSettled {
            ContextMenuItem(title: "Unsettle", systemImage: ConversationSettlementSymbol.unsettle) { unsettle([row.address]) }
        } else if row.canSettle {
            ContextMenuItem(title: "Settle", systemImage: ConversationSettlementSymbol.settle) { settle([row.address]) }
        } else {
            nil
        }
    }

    func readToggle(for row: ConversationSidebarRow) -> ContextMenuItem {
        row.isUnread
            ? ContextMenuItem(title: "Mark as Read", systemImage: "envelope.open") { markRead([row.address]) }
            : ContextMenuItem(title: "Mark as Unread", systemImage: "envelope.badge") { markUnread(row.address) }
    }
}

enum ConversationSettlementSymbol {
    static let settle = "checkmark.circle"
    static let unsettle = "arrow.uturn.backward.circle"
    static let shelf = "checkmark.circle.fill"
}
