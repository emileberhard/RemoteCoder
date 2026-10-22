import Foundation

/// Which agent backend runs a conversation.
///
/// The gateway routes by thread id once a thread exists; the provider is only
/// sent explicitly when starting a new one.
enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case codex
    case claude

    /// Thread ids the gateway assigns to this provider.
    static let claudeThreadPrefix = "claude_"

    static func provider(forThreadID threadID: String) -> AgentProvider {
        threadID.hasPrefix(claudeThreadPrefix) ? .claude : .codex
    }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

enum AgentProviderError: LocalizedError {
    case workingDirectoryRequired(AgentProvider)

    var errorDescription: String? {
        switch self {
        case .workingDirectoryRequired(let provider):
            return "\(provider.displayName) needs a working directory. Pick one from the folder button before sending."
        }
    }
}
