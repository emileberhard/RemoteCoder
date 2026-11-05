import Foundation

enum AgentPrompts {
    static func parentRequest(title: String, threadID: String) -> String {
        "Regarding your agent \"\(title)\" (conversation \(threadID)): "
    }
}
