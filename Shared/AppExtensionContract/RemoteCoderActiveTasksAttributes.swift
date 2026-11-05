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
    }

    struct Fleet: Codable, Hashable {
        struct Host: Codable, Hashable {
            let id: UUID
            let name: String
        }

        let coordinatorID: UUID
        let hosts: [Host]
    }

    let startedAt: Date
    // Activities from builds before the fleet activity have none; they are only retired.
    let fleet: Fleet?

    func tapURL(for state: ContentState) -> URL {
        state.attention?.first.flatMap(url(for:)) ?? RemoteCoderDeepLinks.openApp
    }

    func url(for attention: ContentState.Attention) -> URL? {
        guard let hostID = attention.hostID else { return nil }
        return RemoteCoderDeepLinks.url(for: RemoteCoderConversationLink(
            hostID: hostID, threadID: attention.threadID))
    }

    func unavailableSummary(for state: ContentState) -> String? {
        let unavailable = state.unavailableHostIDs ?? []
        guard let first = unavailable.first else { return nil }
        guard unavailable.count == 1 else { return "\(unavailable.count) hosts unavailable" }
        return "\(fleet?.hosts.first { $0.id == first }?.name ?? "A host") unavailable"
    }
}
