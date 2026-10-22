import Foundation

let maxBufferedNotifications = 1_024

enum RealtimeProbeError: LocalizedError {
    case invalidGatewayEnvironment
    case invalidJSON(String)
    case rpc(method: String, message: String)
    case timedOut(String)
    case missingThreadID
    case initialSettingsNotApplied(String)
    case missingAnswerSDP
    case fixturePlaybackFailed(String)
    case missingMedia(String)
    case voiceSessionBusy
    case microphoneUnauthorized
    case notificationOverflow(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidGatewayEnvironment:
            "~/.remote-coder/codex-gateway.env is missing a port or auth token."
        case .invalidJSON(let context):
            "Invalid JSON while \(context)."
        case .rpc(let method, let message):
            "\(method) failed: \(message)"
        case .timedOut(let phase):
            "Timed out while \(phase)."
        case .missingThreadID:
            "thread/start returned no thread id."
        case .initialSettingsNotApplied(let effort):
            "thread/start did not apply its initial reasoning config; it read back effort \(effort)."
        case .missingAnswerSDP:
            "thread/realtime/sdp contained no SDP answer."
        case .fixturePlaybackFailed(let message):
            "The voice fixture could not be played: \(message)"
        case .missingMedia(let message):
            "Realtime media validation failed: \(message)"
        case .voiceSessionBusy:
            "A realtime voice call is already active. End it before running the probe."
        case .microphoneUnauthorized:
            "macOS microphone access is not authorized for this process. Run the probe from a microphone-authorized process."
        case .notificationOverflow(let phase):
            "More than \(maxBufferedNotifications) notifications arrived unread while \(phase)."
        case .cleanupFailed(let failures):
            "Probe cleanup failed: \(failures)"
        }
    }
}

func isMissingRollout(_ error: any Error) -> Bool {
    guard case RealtimeProbeError.rpc(let method, let message) = error else { return false }
    return method == "thread/archive" && message.localizedCaseInsensitiveContains("no rollout found")
}

struct DelegationTally {
    enum Observation: Equatable {
        case handoffRequested
        case agentStarted
        case commandSucceeded
        case commandFailed
        case agentCompleted
    }

    private(set) var handoffCount = 0
    private(set) var backendTurnCount = 0
    private(set) var completedCommands = 0
    private(set) var failedCommands = 0
    private(set) var sawAgentCompletion = false

    mutating func record(method: String, params: [String: Any]?) throws -> Observation? {
        switch method {
        case "thread/realtime/itemAdded":
            guard let item = params?["item"] as? [String: Any],
                  item["type"] as? String == "handoff_request"
            else { return nil }
            handoffCount += 1
            return .handoffRequested
        case "turn/started":
            backendTurnCount += 1
            return .agentStarted
        case "item/completed":
            guard let item = params?["item"] as? [String: Any],
                  item["type"] as? String == "commandExecution"
            else { return nil }
            guard item["status"] as? String == "completed", item["exitCode"] as? Int == 0 else {
                failedCommands += 1
                return .commandFailed
            }
            completedCommands += 1
            return .commandSucceeded
        case "turn/completed":
            guard handoffCount > 0 else { return nil }
            let turn = params?["turn"] as? [String: Any]
            guard turn?["status"] as? String == "completed" else {
                let status = turn?["status"] as? String ?? "with no status"
                let detail = (turn?["error"] as? [String: Any])?["message"] as? String
                throw RealtimeProbeError.missingMedia(
                    "the delegated agent turn ended \(status)" + (detail.map { ": \($0)" } ?? "")
                )
            }
            sawAgentCompletion = true
            return .agentCompleted
        default:
            return nil
        }
    }

    func verifyDelegation(heardAssistantAfterAgentCompletion: Bool) throws {
        guard backendTurnCount == 1 else {
            throw RealtimeProbeError.missingMedia(
                "one utterance started \(backendTurnCount) delegated agent turns"
            )
        }
        guard handoffCount <= 1 else {
            throw RealtimeProbeError.missingMedia(
                "the realtime model emitted \(handoffCount) handoff notifications for one utterance"
            )
        }
        guard completedCommands > 0 else {
            throw RealtimeProbeError.missingMedia(
                "the delegated agent completed no successful command (\(failedCommands) failed)"
            )
        }
        guard sawAgentCompletion else {
            throw RealtimeProbeError.missingMedia("the delegated agent turn did not complete")
        }
        guard heardAssistantAfterAgentCompletion else {
            throw RealtimeProbeError.missingMedia("no spoken assistant result followed delegation")
        }
    }
}
