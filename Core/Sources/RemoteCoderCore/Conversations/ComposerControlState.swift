import Foundation

enum ComposerSendState: Equatable {
    case idle, working, send, steer, blocked

    init(hasContent: Bool, isWorking: Bool, canSteer: Bool, isBlocked: Bool = false) {
        self = isBlocked ? .blocked : (hasContent ? (canSteer ? .steer : .send) : (isWorking ? .working : .idle))
    }

    init(input: String, hasAttachments: Bool, isPreparingAttachments: Bool,
         isWorking: Bool, canSteer: Bool, isBlocked: Bool) {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.init(hasContent: !isPreparingAttachments && (hasText || hasAttachments),
                  isWorking: isWorking, canSteer: canSteer, isBlocked: isBlocked)
    }

    var canSend: Bool { self == .send || self == .steer }

    var accessibilityLabel: String {
        switch self {
        case .idle, .send: "Send message"
        case .working: "Agent is working"
        case .steer: "Send steering message"
        case .blocked: "Sending unavailable"
        }
    }
}

enum ComposerStopState: Equatable {
    case hidden, ready(RunningTurn), stopping

    init(runningTurn: RunningTurn?, isStopping: Bool) {
        guard let runningTurn else { self = .hidden; return }
        self = isStopping ? .stopping : .ready(runningTurn)
    }
}
