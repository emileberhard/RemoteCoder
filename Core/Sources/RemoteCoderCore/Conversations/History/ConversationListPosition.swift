import Foundation

enum ConversationListPosition: Equatable, Sendable {
    case notLoaded
    case next(String)
    case end

    var canLoad: Bool { self != .end }
    var cursor: String? {
        if case let .next(cursor) = self { return cursor }
        return nil
    }
}

struct ConversationListContinuation: Equatable, Sendable {
    var codex: ConversationListPosition = .notLoaded
    var claude: ConversationListPosition = .notLoaded
    var canLoad: Bool { codex.canLoad || claude.canLoad }
}
