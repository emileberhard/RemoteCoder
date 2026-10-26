import Foundation
import os

enum ServerNotification: Sendable {
    struct TurnAddress: Hashable, Sendable {
        let threadID: String
        let turnID: String
    }

    struct ItemEvent: Sendable {
        let address: TurnAddress
        let item: CodexAppServerV2.ThreadItem
        let startedAtOrdinal: Int64?
        let startedAtMs: Double?
        let completedAtMs: Int64?
        let encodedBytes: Int
    }

    struct TurnCompletion: Sendable {
        let address: TurnAddress
        let status: CodexAppServerV2.TurnStatus?
        let completedAt: Int64?
        let errorMessage: String?
    }

    struct TextDelta: Sendable {
        let address: TurnAddress
        let itemID: String
        let delta: String
        let index: Int?
    }

    struct TurnText: Sendable {
        let address: TurnAddress
        let text: String
    }

    struct QuestionsChanged: Sendable, Equatable {
        let threadID: String
        let epoch: String
        let revision: UInt64
        let itemIDs: [String]
    }

    struct DaemonReady: Sendable, Equatable {
        let epoch: String
        let sequence: UInt64
        let cancelRequest: Bool
        let providerHealth: ProviderHealth?
    }

    struct CallChanged: Decodable, Sendable, Equatable {
        let callId: UUID
        let state: AgentCallStatus.State
    }

    struct TransportError: Sendable, Equatable {
        let kind: String
        let actualBytes: Int?
        let limitBytes: Int?
    }

    case turnStarted(TurnAddress)
    case turnCompleted(TurnCompletion)
    case itemStarted(ItemEvent)
    case itemCompleted(ItemEvent)
    case agentMessageDelta(TextDelta)
    case reasoningSummaryDelta(TextDelta)
    case reasoningTextDelta(TextDelta)
    case planDelta(TextDelta)
    case turnPlanUpdated(TurnText)
    case turnDiffUpdated(TurnText)
    case turnScoped(method: String, address: TurnAddress)
    case threadStarted(threadID: String)
    case threadStatusChanged(threadID: String)
    case threadSettingsUpdated(CodexAppServerV2.ThreadSettingsUpdatedNotification)
    case threadNameUpdated(CodexAppServerV2.ThreadNameUpdatedNotification)
    case threadTokenUsageUpdated(CodexAppServerV2.ThreadTokenUsageUpdatedNotification)
    case threadHistoryInvalidated(threadID: String, removed: Bool)
    case threadArchived(threadID: String, archived: Bool)
    case threadClosed(threadID: String)
    case threadQueueChanged(threadID: String)
    case conversationMarksChanged(ConversationMarks)
    case directoryFavoritesChanged(DirectoryFavorites)
    case preferencesChanged(PreferenceDocument)
    case questionsChanged(QuestionsChanged)
    case daemonReady(DaemonReady)
    case callChanged(CallChanged)
    case gatewayWarning(GatewayWarning)
    case providerHealthChanged(ProviderHealth)
    case activeTurnsChanged(CodexGatewayDaemon.ActiveTurnsResponse)
    case liveActivityChanged(ActiveTasksLiveActivitySnapshot?)
    case transportError(TransportError)
    case unknown(method: String)
    case malformed(method: String, address: TurnAddress?, reason: String)
}

extension ServerNotification {
    var turnAddress: TurnAddress? {
        switch self {
        case .turnStarted(let address), .turnScoped(_, let address), .malformed(_, let address?, _): address
        case .turnCompleted(let completion): completion.address
        case .itemStarted(let event), .itemCompleted(let event): event.address
        case .agentMessageDelta(let delta), .reasoningSummaryDelta(let delta),
             .reasoningTextDelta(let delta), .planDelta(let delta): delta.address
        case .turnPlanUpdated(let text), .turnDiffUpdated(let text): text.address
        case .threadTokenUsageUpdated(let usage): TurnAddress(threadID: usage.threadId, turnID: usage.turnId)
        case .threadStarted, .threadStatusChanged, .threadSettingsUpdated, .threadNameUpdated, .threadHistoryInvalidated, .threadArchived, .threadClosed,
             .threadQueueChanged, .conversationMarksChanged, .directoryFavoritesChanged, .preferencesChanged, .questionsChanged, .daemonReady, .callChanged, .gatewayWarning, .providerHealthChanged, .activeTurnsChanged, .liveActivityChanged, .transportError, .unknown,
             .malformed: nil
        }
    }
}

extension ServerNotification {
    private static let logger = AppLogger(category: "ServerNotification")

    private struct Failure: Error {
        let reason: String
    }

    private struct Envelope<Params: Decodable>: Decodable {
        let params: Params
    }

    private struct Identity: Decodable {
        struct Turn: Decodable { let id: String? }
        let threadId: String?
        let turnId: String?
        let turn: Turn?
    }

    private struct TurnPayload: Decodable {
        struct Turn: Decodable {
            struct Failure: Decodable { let message: String? }
            let status: String?
            let completedAt: Int64?
            let error: Failure?
        }
        let turn: Turn?
    }

    private struct ItemPayload: Decodable {
        let item: CodexAppServerV2.ThreadItem
        let startedAtOrdinal: Int64?
        let startedAtMs: Double?
        let completedAtMs: Int64?
    }

    private struct DeltaPayload: Decodable {
        let threadId: String?
        let turnId: String?
        let turn: Identity.Turn?
        let itemId: String
        let delta: String
        let summaryIndex: Int?
        let contentIndex: Int?
    }

    private struct TextUpdatePayload: Decodable {
        let diff: String?
        let explanation: String?
    }

    private struct ThreadStartedPayload: Decodable {
        struct Thread: Decodable { let id: String }
        let thread: Thread
    }

    private struct ThreadStatusPayload: Decodable {
        let threadId: String
        let status: CodexAppServerV2.ThreadStatus
    }

    private struct ThreadPayload: Decodable {
        let threadId: String
    }

    private struct QuestionsPayload: Decodable {
        let threadId: String
        let epoch: String
        let revision: UInt64
        let itemIds: [String]?
    }

    private struct ReadyPayload: Decodable {
        let notificationEpoch: String
        let notificationSequence: UInt64
        let capabilities: Capabilities?
        let providers: ProviderHealth?
        struct Capabilities: Decodable { let cancelRequest: Bool? }
    }

    private struct ProviderHealthPayload: Decodable {
        let providers: ProviderHealth
    }

    private struct TransportPayload: Decodable {
        let kind: String
        let actualBytes: Int?
        let limitBytes: Int?
    }

    static func decode(method: String, frame: Data) -> ServerNotification {
        do {
            return try decoded(method: method, frame: frame)
        } catch {
            return failed(method: method, address: nil, error: error)
        }
    }

    static func decode(method: String, params: JSONValue?) -> ServerNotification {
        do {
            let frame = try JSONEncoder().encode(CodexAppServerV2.JSONRPC.Notification(method: method, params: params))
            return decode(method: method, frame: frame)
        } catch {
            return failed(method: method, address: nil, error: error)
        }
    }

    private static func decoded(method: String, frame: Data) throws -> ServerNotification {
        if method.hasPrefix("turn/") || method.hasPrefix("item/") {
            return turnScoped(method: method, frame: frame)
        }
        switch method {
        case "thread/started":
            let threadID = try params(ThreadStartedPayload.self, in: frame).thread.id
            guard !threadID.isEmpty else { throw Failure(reason: "empty thread id") }
            return .threadStarted(threadID: threadID)
        case "thread/status/changed":
            let payload = try params(ThreadStatusPayload.self, in: frame)
            guard !payload.threadId.isEmpty else { throw Failure(reason: "empty thread id") }
            return .threadStatusChanged(threadID: payload.threadId)
        case "gateway/warning":
            return .gatewayWarning(try params(GatewayWarning.self, in: frame))
        case "gateway/providerHealth":
            return .providerHealthChanged(try params(ProviderHealthPayload.self, in: frame).providers)
        case "daemon/activeTurns/changed":
            return .activeTurnsChanged(try params(CodexGatewayDaemon.ActiveTurnsResponse.self, in: frame))
        case "daemon/liveActivity/changed":
            return .liveActivityChanged(try params(ActiveTasksLiveActivitySnapshot?.self, in: frame))
        case "thread/settings/updated":
            return .threadSettingsUpdated(try params(CodexAppServerV2.ThreadSettingsUpdatedNotification.self, in: frame))
        case "thread/name/updated":
            return .threadNameUpdated(try params(CodexAppServerV2.ThreadNameUpdatedNotification.self, in: frame))
        case "thread/tokenUsage/updated":
            return .threadTokenUsageUpdated(try params(CodexAppServerV2.ThreadTokenUsageUpdatedNotification.self, in: frame))
        case "thread/reverted", "thread/deleted":
            let threadID = try params(ThreadPayload.self, in: frame).threadId
            guard !threadID.isEmpty else { throw Failure(reason: "empty thread id") }
            return .threadHistoryInvalidated(threadID: threadID, removed: method == "thread/deleted")
        case "thread/archived", "thread/unarchived":
            let threadID = try params(ThreadPayload.self, in: frame).threadId
            guard !threadID.isEmpty else { throw Failure(reason: "empty thread id") }
            return .threadArchived(threadID: threadID, archived: method == "thread/archived")
        case "conversation/marks/changed":
            return .conversationMarksChanged(try params(ConversationMarks.self, in: frame))
        case "directory/favorites/changed":
            return .directoryFavoritesChanged(try params(DirectoryFavorites.self, in: frame))
        case "preferences/changed":
            return .preferencesChanged(try params(PreferenceDocument.self, in: frame))
        case "thread/closed":
            let threadID = try params(ThreadPayload.self, in: frame).threadId
            guard !threadID.isEmpty else { throw Failure(reason: "empty thread id") }
            return .threadClosed(threadID: threadID)
        case "thread/queue/changed":
            let threadID = try params(ThreadPayload.self, in: frame).threadId
            guard !threadID.isEmpty else { throw Failure(reason: "empty thread id") }
            return .threadQueueChanged(threadID: threadID)
        case "conversation/questions/changed":
            let payload = try params(QuestionsPayload.self, in: frame)
            return .questionsChanged(QuestionsChanged(threadID: payload.threadId, epoch: payload.epoch,
                revision: payload.revision, itemIDs: payload.itemIds ?? []))
        case "daemon/ready":
            let payload = try params(ReadyPayload.self, in: frame)
            return .daemonReady(DaemonReady(epoch: payload.notificationEpoch, sequence: payload.notificationSequence,
                cancelRequest: payload.capabilities?.cancelRequest == true, providerHealth: payload.providers))
        case "calls/changed":
            return .callChanged(try params(CallChanged.self, in: frame))
        case "daemon/transportError":
            let payload = try params(TransportPayload.self, in: frame)
            return .transportError(TransportError(kind: payload.kind, actualBytes: payload.actualBytes, limitBytes: payload.limitBytes))
        default:
            return .unknown(method: method)
        }
    }

    private static func turnScoped(method: String, frame: Data) -> ServerNotification {
        switch method {
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/plan/delta":
            if let payload = try? params(DeltaPayload.self, in: frame),
               let threadID = payload.threadId?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty,
               let turnID = payload.turnId ?? payload.turn?.id {
                return textDelta(method: method, payload: payload, address: TurnAddress(threadID: threadID, turnID: turnID))
            }
        default: break
        }
        guard let identity = try? params(Identity.self, in: frame),
              let threadID = identity.threadId?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty,
              let turnID = identity.turnId ?? identity.turn?.id else { return .unknown(method: method) }
        let address = TurnAddress(threadID: threadID, turnID: turnID)
        do {
            switch method {
            case "turn/started":
                return .turnStarted(address)
            case "turn/completed":
                let turn: TurnPayload.Turn?
                do {
                    turn = try params(TurnPayload.self, in: frame).turn
                } catch {
                    report(error, method: method)
                    turn = nil
                }
                return .turnCompleted(TurnCompletion(address: address,
                    status: turn?.status.flatMap(CodexAppServerV2.TurnStatus.init(rawValue:)),
                    completedAt: turn?.completedAt, errorMessage: turn?.error?.message))
            case "item/started", "item/completed":
                let payload = try params(ItemPayload.self, in: frame)
                let event = ItemEvent(address: address, item: payload.item, startedAtOrdinal: payload.startedAtOrdinal,
                    startedAtMs: payload.startedAtMs, completedAtMs: payload.completedAtMs,
                    encodedBytes: (try? JSONEncoder().encode(payload.item).count) ?? 0)
                return method == "item/started" ? .itemStarted(event) : .itemCompleted(event)
            case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/plan/delta":
                return textDelta(method: method, payload: try params(DeltaPayload.self, in: frame), address: address)
            case "turn/plan/updated", "turn/diff/updated":
                let payload = try params(TextUpdatePayload.self, in: frame)
                let text = TurnText(address: address, text: payload.diff ?? payload.explanation ?? "")
                return method == "turn/plan/updated" ? .turnPlanUpdated(text) : .turnDiffUpdated(text)
            default:
                return .turnScoped(method: method, address: address)
            }
        } catch {
            return failed(method: method, address: address, error: error)
        }
    }

    private static func textDelta(method: String, payload: DeltaPayload, address: TurnAddress) -> ServerNotification {
        let index = method.contains("summary") ? payload.summaryIndex : payload.contentIndex
        let delta = TextDelta(address: address, itemID: payload.itemId, delta: payload.delta, index: index)
        switch method {
        case "item/agentMessage/delta": return .agentMessageDelta(delta)
        case "item/reasoning/summaryTextDelta": return .reasoningSummaryDelta(delta)
        case "item/reasoning/textDelta": return .reasoningTextDelta(delta)
        default: return .planDelta(delta)
        }
    }

    private static func failed(method: String, address: TurnAddress?, error: Error) -> ServerNotification {
        .malformed(method: method, address: address, reason: report(error, method: method))
    }

    @discardableResult
    private static func report(_ error: Error, method: String) -> String {
        let reason = describe(error)
        logger.error("malformed notification method=\(method) reason=\(reason)")
        return reason
    }

    private static func params<Params: Decodable>(_ type: Params.Type, in frame: Data) throws -> Params {
        do {
            return try JSONDecoder().decode(Envelope<Params>.self, from: frame).params
        } catch {
            throw Failure(reason: describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.reason }
        guard let error = error as? DecodingError else { return String(describing: type(of: error)) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .typeMismatch(let type, let context): return "type mismatch (\(type)) at \(path(context))"
        case .valueNotFound(let type, let context): return "missing value (\(type)) at \(path(context))"
        case .keyNotFound(let key, let context): return "missing key \(key.stringValue) at \(path(context))"
        case .dataCorrupted(let context): return "corrupted data at \(path(context))"
        @unknown default: return "decoding failed"
        }
    }
}
