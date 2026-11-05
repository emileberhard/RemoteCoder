import Foundation

nonisolated struct ActiveTasksLiveActivityContent: Codable, Hashable, Sendable {
    struct Attention: Codable, Hashable, Sendable, Identifiable {
        var id: String { "\(hostID?.uuidString ?? "")|\(threadID)" }

        enum Reason: String, Codable, Hashable, Sendable {
            case finishedUnread
            case question
        }

        let hostID: UUID?
        let threadID: String
        let title: String?
        let reason: Reason
        let completedAtUnixSeconds: Double?
    }

    let activeTaskCount: Int
    let attention: [Attention]
    let attentionCount: Int
    let unavailableHostIDs: [UUID]

    var isEmpty: Bool { activeTaskCount == 0 && attentionCount == 0 }
    var isCertifiedEmpty: Bool { isEmpty && unavailableHostIDs.isEmpty }
}

nonisolated struct ActiveTasksLiveActivitySnapshot: Codable, Equatable, Sendable {
    let epoch: String
    let revision: UInt64
    let content: ActiveTasksLiveActivityContent
    let relevanceScore: Double
    let updatedAtUnixSeconds: Double
}
