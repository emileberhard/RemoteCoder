import Foundation

enum RealtimeVoiceConversationContextError: LocalizedError {
    case conversationChanged
    case settingsNotLoaded
    case settingsRejected(String)

    var errorDescription: String? {
        switch self {
        case .settingsNotLoaded:
            "Conversation settings are not loaded yet."
        case .settingsRejected(let message):
            message
        case .conversationChanged:
            "The selected conversation changed while Voice Mode was starting. Open Voice Mode again."
        }
    }
}

struct RealtimeVoiceListRequest: Encodable, Sendable {}

struct RealtimeVoiceStartResponse: Decodable, Sendable {
    let realtimeThreadID: String
    let model: String
    let effort: String?

    private enum CodingKeys: String, CodingKey {
        case realtimeThreadID = "realtimeThreadId"
        case model, effort
    }
}

struct RealtimeVoiceListResponse: Decodable, Sendable {
    let voices: [String]
}

struct RealtimeVoiceStartRequest: Encodable, Sendable {
    let conversationThreadID: String
    let realtimeSessionID: String
    let replaceExistingSession: Bool
    let cwd: String
    let model: String
    let effort: String?
    let sdp: String
    let voice: String?
    let initialItems: [RealtimeVoiceInitialItem]

    private enum CodingKeys: String, CodingKey {
        case conversationThreadID = "conversationThreadId"
        case realtimeSessionID = "realtimeSessionId"
        case replaceExistingSession
        case cwd
        case model
        case effort
        case sdp
        case voice
        case initialItems
    }
}

struct RealtimeVoiceStopRequest: Encodable, Sendable {}
struct RealtimeVoiceStopResponse: Decodable, Sendable {}

struct RealtimeVoiceSDPNotification: Decodable, Sendable {
    let threadID: String
    let sdp: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case sdp
    }
}

struct RealtimeVoiceTranscriptDeltaNotification: Decodable, Sendable {
    let threadID: String
    let role: RealtimeVoiceRole
    let delta: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case role
        case delta
    }
}

struct RealtimeVoiceTranscriptDoneNotification: Decodable, Sendable {
    let threadID: String
    let role: RealtimeVoiceRole
    let text: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case role
        case text
    }
}

struct RealtimeVoiceErrorNotification: Decodable, Sendable {
    let threadID: String
    let message: String
    let terminal: Bool?

    var isTerminal: Bool { terminal != false }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case message, terminal
    }
}

struct RealtimeVoiceClosedNotification: Decodable, Sendable {
    let threadID: String
    let reason: String?
    let providerClosed: Bool?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case reason, providerClosed
    }
}

struct RealtimeVoicePreemptedNotification: Decodable, Sendable {
    let realtimeSessionID: String

    private enum CodingKeys: String, CodingKey {
        case realtimeSessionID = "realtimeSessionId"
    }
}

struct RealtimeVoiceAgentEndedNotification: Decodable, Sendable {
    let realtimeSessionID: String

    private enum CodingKeys: String, CodingKey {
        case realtimeSessionID = "realtimeSessionId"
    }
}

enum RealtimeVoiceNotification: Sendable {
    case sdp(RealtimeVoiceSDPNotification)
    case transcriptDelta(RealtimeVoiceTranscriptDeltaNotification)
    case transcriptDone(RealtimeVoiceTranscriptDoneNotification)
    case error(RealtimeVoiceErrorNotification)
    case closed(RealtimeVoiceClosedNotification)
    case preempted(RealtimeVoicePreemptedNotification)
    case agentEnded(RealtimeVoiceAgentEndedNotification)

    init?(_ notification: CodexGatewayNotification) throws {
        guard let params = notification.params else { return nil }
        switch notification.method {
        case "thread/realtime/sdp":
            self = .sdp(try params.decoded(as: RealtimeVoiceSDPNotification.self))
        case "thread/realtime/transcript/delta":
            self = .transcriptDelta(
                try params.decoded(as: RealtimeVoiceTranscriptDeltaNotification.self)
            )
        case "thread/realtime/transcript/done":
            self = .transcriptDone(
                try params.decoded(as: RealtimeVoiceTranscriptDoneNotification.self)
            )
        case "thread/realtime/error":
            self = .error(try params.decoded(as: RealtimeVoiceErrorNotification.self))
        case "thread/realtime/closed":
            self = .closed(try params.decoded(as: RealtimeVoiceClosedNotification.self))
        case "voice/session/preempted":
            self = .preempted(try params.decoded(as: RealtimeVoicePreemptedNotification.self))
        case "voice/session/agentEnded":
            self = .agentEnded(try params.decoded(as: RealtimeVoiceAgentEndedNotification.self))
        default:
            return nil
        }
    }
}

struct RealtimeVoiceConversationContext: Sendable {
    let threadID: String
    let realtimeSessionID: String
    var isProvisionalThread: Bool
    var model: String
    var effort: String?
    let cwd: String
    var fastModeState: FastModeState
    let history: [RealtimeVoiceHistoryMessage]

    var fastModeSelection: Bool? { fastModeState.selection }

    var initialItems: [RealtimeVoiceInitialItem] {
        RealtimeVoiceConversationHistory.initialItems(from: history)
    }

    func applying(_ settings: ConversationSettingsUpdate,
                  modelAndEffort: Bool = true, fastMode: Bool = true) -> Self {
        guard settings.threadId == threadID else { return self }
        var updated = self
        if modelAndEffort {
            updated.model = settings.model
            updated.effort = settings.effort
        }
        if fastMode {
            switch settings.fastModeState {
            case .selection:
                updated.fastModeState = settings.fastModeState
            case .readback:
                let remembered = AgentProvider.provider(forModelID: settings.model) == AgentProvider.provider(forModelID: model)
                    ? fastModeState.remembered : nil
                updated.fastModeState = settings.fastModeState.restoringPreference(remembered)
            }
        }
        return updated
    }

    func refreshingHistory(
        chatMessages: [RealtimeVoiceHistoryMessage], voiceMessages: [RealtimeVoiceHistoryMessage]
    ) -> Self {
        Self(
            threadID: threadID, realtimeSessionID: realtimeSessionID,
            isProvisionalThread: isProvisionalThread, model: model, effort: effort, cwd: cwd,
            fastModeState: fastModeState,
            history: RealtimeVoiceConversationHistory.merged(
                chatMessages: chatMessages.isEmpty ? history : chatMessages, voiceMessages: voiceMessages
            )
        )
    }
}
