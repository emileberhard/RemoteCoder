import Foundation

struct ConversationSidebarSection: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pinned(ConversationSectionSummary)
        case automations(ConversationSectionSummary)
        case chats
        case project(ConversationProjectHeader)
        case settled(ConversationSectionSummary, hiddenRowCount: Int)
        case unsectioned
    }

    let kind: Kind
    let rows: [ConversationSidebarRow]

    var id: String {
        switch kind {
        case .pinned: "pinned"
        case .automations: "automations"
        case .chats: "chats"
        case let .project(header): "project|\(header.key)"
        case .settled: "settled"
        case .unsectioned: "unsectioned"
        }
    }
}

enum ConversationSidebarSections {
    static func sections(of items: [ConversationSidebarItem]) -> [ConversationSidebarSection] {
        var sections: [ConversationSidebarSection] = []
        var kind = ConversationSidebarSection.Kind.unsectioned
        var rows: [ConversationSidebarRow] = []
        func close() {
            let isFoldable = switch kind {
            case .pinned, .automations, .project, .settled: true
            case .chats, .unsectioned: false
            }
            if !rows.isEmpty || isFoldable {
                sections.append(ConversationSidebarSection(kind: kind, rows: rows))
            }
            rows = []
        }
        for item in items {
            switch item {
            case let .pinnedHeader(summary):
                close()
                kind = .pinned(summary)
            case let .automationsHeader(summary):
                close()
                kind = .automations(summary)
            case .chatsHeader:
                close()
                kind = .chats
            case let .project(header):
                close()
                kind = .project(header)
            case let .settledHeader(summary):
                close()
                kind = .settled(summary, hiddenRowCount: 0)
            case let .moreSettled(hiddenCount):
                if case let .settled(summary, _) = kind { kind = .settled(summary, hiddenRowCount: hiddenCount) }
            case let .row(row):
                rows.append(row)
            case .more:
                break
            }
        }
        close()
        return sections
    }
}
