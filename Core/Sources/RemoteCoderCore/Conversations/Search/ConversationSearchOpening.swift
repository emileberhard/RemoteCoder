import Foundation

struct ConversationSearchOpening: Sendable, Equatable {
    let itemKey: String
    let findTerm: String?
}

extension ConversationSearchLocation {
    struct Reveal: Sendable, Equatable {
        let rowID: String
        var groupToExpand: String? = nil
    }

    @concurrent
    func reveal(in items: [ChatStreamItem]) async -> Reveal? {
        let jobID = turnId.map { GatewayNotificationRouting.jobID(threadID: threadId, turnID: $0) }
        if let itemId {
            let eventID = jobID.map { "\($0)-\(itemId)" }
            for item in items {
                switch item {
                case .message(let message) where message.canonicalItemID == itemId: return Reveal(rowID: item.id)
                case .question(let question) where question.itemID == itemId: return Reveal(rowID: item.id)
                case .viewedMedia(let media) where media.itemID == itemId: return Reveal(rowID: item.id)
                case .publishedVisual(let visual) where visual.itemID == itemId: return Reveal(rowID: item.id)
                case .compaction(let marker) where marker.compaction.itemID == itemId: return Reveal(rowID: item.id)
                case .timeline(let group):
                    if let eventID, group.events.contains(where: { $0.id == eventID }) {
                        return Reveal(rowID: ChatStreamItem.activityRowID(eventID: eventID), groupToExpand: group.isExpanded ? nil : group.id)
                    }
                default: continue
                }
            }
        }
        guard let turnId else { return nil }
        let row = items.first { item in
            switch item {
            case .message(let message): return message.canonicalTurnID == turnId
            case .question(let question): return question.turnID == turnId
            case .publishedVisual(let visual): return visual.turnID == turnId
            case .compaction(let marker): return marker.compaction.turnID == turnId
            case .turnOutcome(let outcome): return outcome.turnID == turnId
            default: return false
            }
        }
        return row.map { Reveal(rowID: $0.id) }
    }
}
