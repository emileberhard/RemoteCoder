import Foundation

/// A conversation's full identity across gateway hosts.
///
/// Thread ids are only unique within one gateway, so every sidebar row,
/// selection comparison, pin command and action route carries the owning host.
struct ConversationAddress: Hashable, Codable, Sendable, Identifiable {
    let hostID: UUID
    let threadID: String

    var target: ExecutionTarget { ExecutionTarget(hostID: hostID) }
    var id: String { Self.id(targetID: target.id, threadID: threadID) }

    static func id(targetID: String, threadID: String) -> String { "\(targetID)|\(threadID)" }

    var codexDesktopLink: String? {
        guard AgentProvider.provider(forThreadID: threadID) == .codex else { return nil }
        return "codex://threads/\(threadID)"
    }
}
