import Foundation

struct ForkOrigin: Equatable, Sendable {
    let source: ConversationAddress
    let sourceTitle: String?

    var label: String { "Forked from \(sourceTitle ?? "another conversation")" }
}
