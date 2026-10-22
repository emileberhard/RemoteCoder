import Foundation

struct TaskCompletionNotificationPayload: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case codex, claude, shell, unknown
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: value) ?? .unknown
        }
    }
    enum Outcome: String, Codable, Sendable { case success, failure }

    let eventID: String
    let source: Source
    /// Absent on question alerts, which have no turn outcome.
    let outcome: Outcome?
    let conversationID: UUID?
    let sessionID: String?
    let hostID: UUID
    let promptPreview: String
    let messagePreview: String
    let workingDirectory: String?
    let createdAtUnixSeconds: TimeInterval
    /// Present on "Codex has a question" alerts: the async question item whose
    /// card the tap should open. Absent on completion alerts.
    var questionItemID: String?

    /// Names the broker event across hosts. A turn and a
    /// question keep the gateway's canonical event ID; the client never derives it.
    var presentationID: String? {
        guard !eventID.isEmpty else { return nil }
        return "\(hostID.uuidString)|default|\(eventID)"
    }

    var title: String {
        let provider = source == .claude ? "Claude" : source == .codex ? "Codex" : "Task"
        if questionItemID != nil { return "\(provider) has a question" }
        return outcome == .success ? "\(provider) finished" : "\(provider) ended"
    }

    var createdAt: Date { Date(timeIntervalSince1970: createdAtUnixSeconds) }

}
