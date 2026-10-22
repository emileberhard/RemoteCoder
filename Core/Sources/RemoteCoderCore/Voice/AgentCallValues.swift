import Foundation

struct AgentCallPush: Codable, Equatable, Sendable {
    let callId: UUID
    let hostId: UUID
    let expiresAt: TimeInterval

    func isCurrent(at date: Date) -> Bool {
        expiresAt.isFinite && expiresAt > date.timeIntervalSince1970
    }
}

struct AgentCallStatus: Decodable, Sendable {
    enum State: String, Decodable, Sendable {
        case requested, delivering, ringing, connecting, connected, ending, ended, unresolved

        var isTerminal: Bool { self == .ended || self == .unresolved }
    }

    let callId: UUID
    let conversationThreadId: String
    let provider: String
    let state: State
    let expiresAt: TimeInterval
    let cwd: String
    let model: String
    let effort: String?

    func voiceContext(for push: AgentCallPush, at date: Date) throws -> RealtimeVoiceConversationContext {
        guard callId == push.callId, state == .delivering || state == .ringing,
              expiresAt.isFinite, expiresAt > date.timeIntervalSince1970,
              !conversationThreadId.isEmpty, !cwd.isEmpty, !model.isEmpty,
              AgentProvider.provider(forThreadID: conversationThreadId).rawValue == provider else {
            throw AgentIncomingCallError.unavailable
        }
        return RealtimeVoiceConversationContext(
            threadID: conversationThreadId,
            realtimeSessionID: callId.uuidString.lowercased(),
            isProvisionalThread: false,
            model: model,
            effort: effort,
            cwd: cwd,
            fastModeState: .readback(nil, remembered: nil),
            history: []
        )
    }
}

enum AgentIncomingCallError: LocalizedError {
    case unavailable
    case hostIdentityChanged

    var errorDescription: String? {
        switch self {
        case .unavailable: "This incoming call is no longer available."
        case .hostIdentityChanged: "The gateway's incoming-call identity changed. Re-enroll the host before accepting calls."
        }
    }
}
