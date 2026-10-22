import Foundation

enum ConversationSidebarNavigation {
    enum Direction: Sendable {
        case previous, next
    }

    static func rows(of items: [ConversationSidebarItem]) -> [ConversationSidebarRow] {
        items.compactMap { item in
            if case .row(let row) = item { row } else { nil }
        }
    }

    static func neighbor(
        _ direction: Direction, of current: ConversationAddress?, in rows: [ConversationSidebarRow]
    ) -> ConversationAddress? {
        guard let index = current.flatMap({ current in rows.firstIndex { $0.address == current } }) else {
            return direction == .next ? rows.first?.address : rows.last?.address
        }
        let neighbor = direction == .next ? index + 1 : index - 1
        return rows.indices.contains(neighbor) ? rows[neighbor].address : nil
    }

    static func address(atPosition position: Int, in rows: [ConversationSidebarRow]) -> ConversationAddress? {
        rows.indices.contains(position - 1) ? rows[position - 1].address : nil
    }

    static func nextNeedingAttention(
        after current: ConversationAddress?, in rows: [ConversationSidebarRow]
    ) -> ConversationAddress? {
        let start = current.flatMap { current in rows.firstIndex { $0.address == current } }
        let candidates = start.map { Array(rows[($0 + 1)...] + rows[..<$0]) } ?? rows
        return candidates.first { ($0.questionCount ?? 0) > 0 }?.address
            ?? candidates.first(where: \.isUnread)?.address
    }
}
