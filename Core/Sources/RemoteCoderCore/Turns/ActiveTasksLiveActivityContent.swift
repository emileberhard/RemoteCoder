import Foundation

nonisolated struct ActiveTasksLiveActivityContent: Codable, Hashable, Sendable {
    struct Attention: Codable, Hashable, Sendable, Identifiable {
        var id: String { threadID }

        enum Reason: String, Codable, Hashable, Sendable {
            case finishedUnread
            case question
        }

        let threadID: String
        let accountID: UUID?
        let title: String?
        let reason: Reason
        let completedAtUnixSeconds: Double?
    }

    let activeTaskCount: Int
    let attention: [Attention]
    let attentionCount: Int

    var isEmpty: Bool { activeTaskCount == 0 && attentionCount == 0 }
}

nonisolated struct ActiveTasksLiveActivitySnapshot: Codable, Equatable, Sendable {
    let epoch: String
    let revision: UInt64
    let content: ActiveTasksLiveActivityContent
    let relevanceScore: Double
    let updatedAtUnixSeconds: Double
}
