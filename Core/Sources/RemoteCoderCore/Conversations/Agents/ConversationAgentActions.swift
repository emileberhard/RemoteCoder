import Foundation

enum ConversationAgentNavigationError: LocalizedError {
    case hostUnavailable
    case noConversation

    var errorDescription: String? {
        switch self {
        case .hostUnavailable: "The agent's host is not available."
        case .noConversation: "This agent does not expose a separate conversation."
        }
    }
}

struct SubagentContext: Equatable, Sendable {
    let threadID: String
    let title: String
    let parent: ConversationAddress
    let parentTitle: String?
}
