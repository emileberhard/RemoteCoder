import Foundation

/// Typed result of routing one gateway broadcast notification.
enum RoutedGatewayEvent: Sendable {
    case tokenUsage(CodexAppServerV2.ThreadTokenUsageUpdatedNotification, sequence: UInt64?)
    case turnEvent(TurnScopedGatewayEvent)
    case historyInvalidated(threadID: String, removed: Bool, sequence: UInt64?)
    case archive(threadID: String, archived: Bool, sequence: UInt64?)
    case marks(ConversationMarks)
    case favorites(DirectoryFavorites)
    case preferences(PreferenceDocument)
    case settings(CodexAppServerV2.ThreadSettingsUpdatedNotification, sequence: UInt64?)
    case threadName(CodexAppServerV2.ThreadNameUpdatedNotification)
    case queueChanged(threadID: String)
    case warning(GatewayWarning)
    case activity(CodexGatewayDaemon.ActiveTurnsResponse)
    case liveActivity(ActiveTasksLiveActivitySnapshot?)

    var sequence: UInt64? {
        switch self {
        case .tokenUsage(_, let sequence), .historyInvalidated(_, _, let sequence),
             .archive(_, _, let sequence), .settings(_, let sequence): sequence
        case .turnEvent(let event): event.sequence
        case .threadName, .queueChanged, .marks, .favorites, .preferences, .warning, .activity, .liveActivity: nil
        }
    }
}

/// A turn- or item-scoped notification with its identity and payloads already
/// extracted, so the main actor applies state without touching raw JSON.
struct TurnScopedGatewayEvent: Sendable {
    let note: CodexGatewayNotification
    let sequence: UInt64?
    let method: String
    let threadID: String
    let turnID: String
    let normalizedTurnID: String
    let jobID: String

    var isLifecycle: Bool {
        switch method {
        case "turn/started", "turn/completed", "item/started", "item/completed": true
        default: false
        }
    }

    var item: CodexAppServerV2.ThreadItem? {
        switch note.server {
        case .itemStarted(let event), .itemCompleted(let event): event.item
        default: nil
        }
    }

    var itemID: String? {
        switch note.server {
        case .itemStarted(let event), .itemCompleted(let event): event.item.id
        case .agentMessageDelta(let delta), .reasoningSummaryDelta(let delta),
             .reasoningTextDelta(let delta), .planDelta(let delta): delta.itemID
        default: nil
        }
    }
}

/// Off-main prefilter for the gateway's global notification broadcast: drops
/// methods the app ignores, extracts turn identity, and decodes typed payloads
/// before the single hop that applies surviving events to main-actor state.
enum GatewayNotificationRouting {
    static func normalizeTurnID(_ raw: String) -> String {
        if raw.hasPrefix("turn-") { return String(raw.dropFirst("turn-".count)) }
        if raw.hasPrefix("turn_") { return String(raw.dropFirst("turn_".count)) }
        return raw
    }

    static func jobID(threadID: String, turnID: String) -> String {
        "gw-\(threadID)-\(normalizeTurnID(turnID))"
    }

    /// Exact inverse of `jobID(threadID:turnID:)` for a known thread, so state
    /// that only kept a job id (processing rows) can still name its turn.
    static func normalizedTurnID(fromJobID jobID: String, threadID: String) -> String? {
        let prefix = "gw-\(threadID)-"
        guard jobID.hasPrefix(prefix) else { return nil }
        let turnID = String(jobID.dropFirst(prefix.count))
        return turnID.isEmpty ? nil : turnID
    }

    static func route(_ note: CodexGatewayNotification) -> RoutedGatewayEvent? {
        switch note.server {
        case .gatewayWarning(let warning):
            return .warning(warning)
        case .activeTurnsChanged(let snapshot):
            return .activity(snapshot)
        case .liveActivityChanged(let snapshot):
            return .liveActivity(snapshot)
        case .threadSettingsUpdated(let settings):
            return .settings(settings, sequence: note.sequence)
        case .threadNameUpdated(let name):
            return .threadName(name)
        case .threadHistoryInvalidated(let threadID, let removed):
            return .historyInvalidated(threadID: threadID, removed: removed, sequence: note.sequence)
        case .threadArchived(let threadID, let archived):
            return .archive(threadID: threadID, archived: archived, sequence: note.sequence)
        case .threadQueueChanged(let threadID):
            return .queueChanged(threadID: threadID)
        case .conversationMarksChanged(let marks):
            return .marks(marks)
        case .directoryFavoritesChanged(let favorites):
            return .favorites(favorites)
        case .preferencesChanged(let preferences):
            return .preferences(preferences)
        case .threadTokenUsageUpdated(let usage):
            return .tokenUsage(usage, sequence: note.sequence)
        case .threadClosed, .questionsChanged, .daemonReady, .callChanged, .transportError, .unknown:
            return nil
        case .turnStarted, .turnCompleted, .itemStarted, .itemCompleted, .agentMessageDelta, .reasoningSummaryDelta,
             .reasoningTextDelta, .planDelta, .turnPlanUpdated, .turnDiffUpdated, .turnScoped, .malformed:
            guard let address = note.server.turnAddress else { return nil }
            return .turnEvent(
                TurnScopedGatewayEvent(
                    note: note,
                    sequence: note.sequence,
                    method: note.method,
                    threadID: address.threadID,
                    turnID: address.turnID,
                    normalizedTurnID: normalizeTurnID(address.turnID),
                    jobID: jobID(threadID: address.threadID, turnID: address.turnID)
                )
            )
        }
    }

    /// Replayed raw messages reuse the same routing as live notifications.
    static func route(replayed entry: CodexGatewayDaemon.ReplayedNotification) -> RoutedGatewayEvent? {
        guard case .object(let obj) = entry.message else { return nil }
        guard let methodValue = obj["method"], case .string(let method) = methodValue else { return nil }
        return route(
            CodexGatewayNotification(
                method: method,
                params: obj["params"],
                server: ServerNotification.decode(method: method, params: obj["params"]),
                receivedAt: Date(timeIntervalSince1970: entry.timestampUnixSeconds),
                sequence: entry.sequence
            )
        )
    }
}

struct GatewayWarning: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case historyIdentityPersistence }
    let kind: Kind
    let threadId: String?
    let message: String
}
