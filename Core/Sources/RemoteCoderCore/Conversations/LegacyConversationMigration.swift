import Foundation

/// Read-only migration of the retired, unscoped timeline cache. New writes use canonical checkpoints.
/// The old file remains available for rollback; once a checkpoint exists it is never imported again.
enum LegacyConversationMigration {
    private struct Envelope: Decodable { let version: Int; let timelines: [Timeline] }
    private struct Timeline: Decodable {
        let id: String
        let conversationID: UUID
        let sessionID: String?
        let startedAt: Date
        let anchorDate: Date
        let completedAt: Date?
        let workingDirectory: String?
        let events: [Event]
    }
    private struct Event: Decodable {
        let id: String
        let sequence: Int
        let kind: String
        let title: String
        let subtitle: String?
        let timestamp: Date?
        let details: [JobTimelineEventDetail]
    }

    @concurrent
    static func read(conversationID: UUID, threadID: String?, directory: URL) async throws -> ConversationState.Checkpoint? {
        let file = directory.appending(path: "\(conversationID).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: file))
        guard envelope.version == 1 else { throw MigrationError.unsupportedVersion(envelope.version) }
        var state = ConversationState(conversationID: conversationID, threadID: threadID)
        for timeline in envelope.timelines.sorted(by: { $0.anchorDate < $1.anchorDate })
            where timeline.conversationID == conversationID && timeline.sessionID == threadID {
            let base = timeline.id.components(separatedBy: "-seg-")[0]
            let prefix = threadID.map { "gw-\($0)-" }
            let remote = prefix.map { base.hasPrefix($0) } == true
            let turnID: String
            if let prefix, remote {
                turnID = String(base.dropFirst(prefix.count))
            } else {
                turnID = ConversationState.localTurnID(base)
            }
            var turn = state.turns[turnID] ?? ConversationState.Turn(id: turnID)
            turn.startedAt = turn.startedAt ?? timeline.startedAt
            turn.completedAt = timeline.completedAt ?? turn.completedAt
            turn.terminal = timeline.completedAt != nil
            for event in timeline.events where event.kind != "status" && event.kind != "start" {
                let id = event.id.hasPrefix("\(base)-") ? String(event.id.dropFirst(base.count + 1)) : event.id
                turn.items[id] = ConversationState.Item(value: .unknown(id: id, type: "legacyActivity", payload: .null),
                    date: event.timestamp, completed: false, detailed: false, isLocal: !remote,
                    activity: JobTimelineEvent(id: event.id, sequence: event.sequence,
                        kind: JobTimelineEventKind(rawValue: event.kind) ?? .unknown, title: event.title,
                        subtitle: event.subtitle, timestamp: event.timestamp, details: event.details))
                if !turn.order.contains(id) { turn.order.append(id) }
            }
            guard !turn.order.isEmpty else { continue }
            state.turns[turnID] = turn
            if !state.order.contains(turnID) { state.order.append(turnID) }
        }
        guard !state.order.isEmpty else { return nil }
        state.markPersistedChange()
        return state.checkpoint
    }

    private enum MigrationError: Error { case unsupportedVersion(Int) }
}
