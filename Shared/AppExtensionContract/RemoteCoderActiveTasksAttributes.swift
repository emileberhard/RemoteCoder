import ActivityKit
import Foundation

struct RemoteCoderActiveTasksAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        typealias Attention = ActiveTasksLiveActivityContent.Attention

        let activeTaskCount: Int
        // Absent until the gateway authors the content, and from older daemon versions.
        let attention: [Attention]?
        let attentionCount: Int?
        let unavailableHostIDs: [UUID]?
        // Keep the state JSON-serializable for potential remote (APNs) Live Activity updates.
        let updatedAtUnixSeconds: Double

        var unavailableSummary: String? {
            switch unavailableHostIDs?.count ?? 0 {
            case 0: nil
            case 1: "1 host unavailable"
            case let count: "\(count) hosts unavailable"
            }
        }
    }

    let startedAt: Date
    // Activities from builds before the fleet activity have none; they are only retired.
    let coordinatorID: UUID?

    func tapURL(for state: ContentState) -> URL {
        state.attention?.first.flatMap(url(for:)) ?? RemoteCoderDeepLinks.openApp
    }

    func url(for attention: ContentState.Attention) -> URL? {
        guard let hostID = attention.hostID else { return nil }
        return RemoteCoderDeepLinks.url(for: RemoteCoderConversationLink(
            hostID: hostID, threadID: attention.threadID))
    }
}
