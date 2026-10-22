import ActivityKit
import Foundation

struct RemoteCoderActiveTasksAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        typealias Attention = ActiveTasksLiveActivityContent.Attention

        let activeTaskCount: Int
        // Absent until the gateway authors the content, and from older daemon versions.
        let attention: [Attention]?
        let attentionCount: Int?
        // Keep the state JSON-serializable for potential remote (APNs) Live Activity updates.
        let updatedAtUnixSeconds: Double
    }

    let startedAt: Date
    // One aggregate activity per gateway host. Optional so activities requested
    // by an earlier build still decode; those are treated as legacy and are only
    // ever retired, never adopted by a host.
    let hostID: UUID?
    let hostName: String?

    func tapURL(for state: ContentState) -> URL {
        state.attention?.first.flatMap(url(for:)) ?? RemoteCoderDeepLinks.openApp
    }

    func url(for attention: ContentState.Attention) -> URL? {
        guard let hostID else { return nil }
        return RemoteCoderDeepLinks.url(for: RemoteCoderConversationLink(
            hostID: hostID, threadID: attention.threadID))
    }
}
