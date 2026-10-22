import Foundation

enum ChatStreamItem: Identifiable, Sendable, Equatable {
    case message(ChatMessage)
    case question(QuestionPrompt)
    case timeline(JobTimeline)
    case historyEdge(HistoryEdge)
    case turnOutcome(TurnOutcome)
    case viewedMedia(ViewedMedia)
    case publishedVisual(PublishedVisual)
    case compaction(CompactionMarker)

    static func questionRowID(itemID: String) -> String { "question-\(itemID)" }
    static func activityRowID(eventID: String) -> String { "activity-\(eventID)" }

    var id: String {
        switch self {
        case .historyEdge(let edge): return edge.id
        case .message(let message):
            return "message-\(message.id.uuidString)"
        case .question(let prompt):
            return Self.questionRowID(itemID: prompt.itemID)
        case .timeline(let timeline):
            return "timeline-\(timeline.id)"
        case .turnOutcome(let outcome):
            return "outcome-\(outcome.turnID)"
        case .viewedMedia(let media):
            return media.rowID
        case .publishedVisual(let visual):
            return visual.rowID
        case .compaction(let marker):
            return marker.id
        }
    }
}

/// Canonical markers keep their position and identity through completion and history reads.
struct CompactionMarker: Sendable, Equatable {
    let id: String
    var compaction: ConversationCompaction
}

struct ViewedMedia: Sendable, Equatable {
    let itemID: String
    let index: Int
    let path: String
    let caption: String

    var rowID: String { "viewed-media-\(itemID)-\(index)" }
}

struct PublishedVisual: Sendable, Equatable {
    let itemID: String
    let publication: HTMLVisualPublication

    var rowID: String { "published-visual-\(itemID)" }
}

struct TurnOutcome: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case failed(message: String?)
        case noReply
    }

    let turnID: String
    let kind: Kind
    let date: Date
}

extension [ChatStreamItem] {
    func differsOnlyInStreamingText(from previous: [ChatStreamItem]) -> Bool {
        count == previous.count && zip(previous, self).allSatisfy { old, new in
            guard case .message(var shown) = old, case .message(let next) = new, shown.isStreaming, next.isStreaming else {
                return old == new
            }
            shown.text = next.text
            return shown == next
        }
    }

    var endsAtNewerHistoryEdge: Bool {
        if case .historyEdge(let edge) = last { edge.kind == .newer } else { false }
    }
}
