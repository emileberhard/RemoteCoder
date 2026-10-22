import Foundation

struct RealtimeVoiceLifecycle: Sendable {
    enum State: Equatable, Sendable {
        case idle
        case ringing
        case connecting
        case listening
        case speaking
        case reconnecting
        case stopping
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Ready"
            case .ringing: "Incoming call"
            case .connecting: "Connecting…"
            case .listening: "Listening"
            case .speaking: "Speaking"
            case .reconnecting: "Reconnecting…"
            case .stopping: "Ending call…"
            case .failed: "Connection failed"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var callID: UUID?
    private(set) var connectionID: UUID?

    static func stateAfterClosure(reason: String?, providerClosed: Bool) -> State {
        switch reason {
        case "transport_closed" where !providerClosed: .reconnecting
        case "requested" where !providerClosed: .idle
        case "close_requested", "remote_hangup": .idle
        case "expired": .failed("The voice session expired.")
        case "content": .failed("The voice session was closed by the provider.")
        case "connection_lost": .failed("The voice connection was lost.")
        default: .failed("The voice session closed unexpectedly.")
        }
    }

    var isActive: Bool { callID != nil && state != .stopping }

    mutating func start(callID: UUID) -> Bool {
        guard self.callID == nil else { return false }
        self.callID = callID
        state = .connecting
        return true
    }

    mutating func receiveIncoming(callID: UUID) -> Bool {
        guard self.callID == nil else { return false }
        self.callID = callID
        state = .ringing
        return true
    }

    func isCurrentCall(_ id: UUID) -> Bool {
        isActive && callID == id
    }

    func ownsConnection(_ id: UUID) -> Bool {
        callID != nil && connectionID == id
    }

    func isCurrentConnection(_ id: UUID) -> Bool {
        isActive && ownsConnection(id)
    }

    mutating func beginConnection(callID: UUID, reconnecting: Bool) -> UUID? {
        guard isCurrentCall(callID) else { return nil }
        let id = UUID()
        connectionID = id
        state = reconnecting ? .reconnecting : .connecting
        return id
    }

    mutating func update(_ state: State, connectionID: UUID) {
        guard isCurrentConnection(connectionID) else { return }
        self.state = state
    }

    mutating func beginStop() -> UUID? {
        guard isActive, let callID else { return nil }
        state = .stopping
        return callID
    }

    mutating func finishStop(callID: UUID, finalState: State) {
        guard self.callID == callID, state == .stopping else { return }
        self.callID = nil
        connectionID = nil
        state = finalState
    }
}
