import Foundation

struct HTMLVisualReplyIndex: Sendable, Equatable {
    private let replies: [HTMLVisualReplyKey: [String]]?

    static let unknown = HTMLVisualReplyIndex(replies: nil)

    private init(replies: [HTMLVisualReplyKey: [String]]?) {
        self.replies = replies
    }

    init(messages: [ChatMessage], includesNewest: Bool) {
        guard includesNewest else {
            self = .unknown
            return
        }
        var replies: [HTMLVisualReplyKey: [String]] = [:]
        for message in messages where message.role == .user && message.delivery != .notSent {
            for reply in message.visualReplies ?? [] { replies[reply.key, default: []].append(reply.text) }
        }
        self.init(replies: replies)
    }

    func sent(for key: HTMLVisualReplyKey) -> [String]? {
        replies.map { $0[key] ?? [] }
    }
}
