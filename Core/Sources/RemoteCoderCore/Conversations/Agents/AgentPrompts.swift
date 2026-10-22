import Foundation

extension ConversationAgent {
    var parentRequest: String {
        "Regarding your agent \"\(title)\" (\(id))\(threadId.map { ", conversation \($0)" } ?? ""): "
    }
}
