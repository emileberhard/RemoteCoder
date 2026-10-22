import Foundation

enum QuickEntryRecents {
    static func rows(from items: [ConversationSidebarItem], limit: Int) -> [ConversationSidebarRow] {
        let rows: [ConversationSidebarRow] = items.compactMap { item in
            guard case .row(let row) = item, !row.isAutomation || row.isPinned else { return nil }
            return row
        }
        return Array(rows.sorted(by: precedes).prefix(limit))
    }

    private static func precedes(_ lhs: ConversationSidebarRow, _ rhs: ConversationSidebarRow) -> Bool {
        if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
        if lhs.sidebarDate != rhs.sidebarDate { return lhs.sidebarDate > rhs.sidebarDate }
        return lhs.id < rhs.id
    }
}
