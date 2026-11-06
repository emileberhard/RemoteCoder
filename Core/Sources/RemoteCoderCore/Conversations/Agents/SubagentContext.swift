import Foundation

struct SubagentContext: Equatable, Sendable {
    let threadID: String
    let title: String
    let parent: ConversationAddress
    let parentTitle: String?

    var parentRequest: String { "Regarding your agent \"\(title)\" (conversation \(threadID)): " }
}
