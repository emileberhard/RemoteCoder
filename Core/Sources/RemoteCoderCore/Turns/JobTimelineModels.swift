import Foundation

enum JobTimelineEventKind: String, Sendable, Codable {
    case start
    case progress
    case toolCall
    case toolResult
    case toolError
    case message
    case status
    case error
    case unknown
}

struct JobTimelineEventDetail: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let label: String
    let value: String
}

struct JobTimelineEvent: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let sequence: Int
    let kind: JobTimelineEventKind
    let title: String
    let subtitle: String?
    let timestamp: Date?
    let details: [JobTimelineEventDetail]
}

struct JobTimeline: Identifiable, Sendable, Equatable {
    let id: String
    let startedAt: Date?
    let anchorDate: Date
    let completedAt: Date?
    let isLive: Bool
    let isExpanded: Bool
    let events: [JobTimelineEvent]
}

/// Resolves the wall-clock span a timeline row represents.
///
/// A row covers the gap between one agent output and the next, so its span is
/// bounded by the messages on either side of it — never by the enclosing turn.
/// Deriving it from turn timestamps made every row report the whole turn's
/// elapsed time, and for a turn still streaming that number kept growing.
///
/// Every fallback here is a real observation (a message time, an event time).
/// When none exists the span is unknown, and callers show no duration at all
/// rather than a fabricated one.
enum JobTimelineSpan {
    static func startedAt(precedingMessageDate: Date?, events: [JobTimelineEvent]) -> Date? {
        precedingMessageDate ?? events.compactMap(\.timestamp).min()
    }

    static func completedAt(
        followingMessageDate: Date?,
        events: [JobTimelineEvent],
        isRunning: Bool
    ) -> Date? {
        guard isRunning == false else { return nil }
        return followingMessageDate ?? events.compactMap(\.timestamp).max()
    }

    /// Spans shorter than this read as noise (same-second stamps, clock skew).
    static let minimumDisplayedDuration: TimeInterval = 1

    static func displayDuration(startedAt: Date?, completedAt: Date?) -> TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        let duration = completedAt.timeIntervalSince(startedAt)
        guard duration >= minimumDisplayedDuration else { return nil }
        return duration
    }
}

