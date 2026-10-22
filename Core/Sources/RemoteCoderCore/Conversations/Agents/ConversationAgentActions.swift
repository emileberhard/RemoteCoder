import Foundation

enum ConversationAgentAction: String, Sendable {
    case message, `continue`, stop
}

struct AgentNavigation: Equatable, Sendable {
    let parent: ConversationAddress
    let child: ConversationAddress
}

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
