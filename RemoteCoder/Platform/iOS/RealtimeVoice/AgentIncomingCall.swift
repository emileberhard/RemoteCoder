import Foundation
import CallKit
import OSLog

extension AgentCallFailure {
    init(_ error: Error) {
        let value = error as NSError
        let reason: String
        if value.domain == CXErrorDomainIncomingCall,
           let callError = CXErrorCodeIncomingCallError.Code(rawValue: value.code) {
            reason = switch callError {
            case .filteredByDoNotDisturb: "filteredByDoNotDisturb"
            case .filteredByBlockList: "filteredByBlockList"
            case .callUUIDAlreadyExists: "callUUIDAlreadyExists"
            case .unentitled: "unentitled"
            default: "incomingCallRejected"
            }
        } else {
            reason = String(value.localizedDescription.prefix(1_000))
        }
        self.init(domain: value.domain, code: value.code, reason: reason)
    }
}

enum AgentCallDiagnostics {
    private static let logger = AppLogger(category: "AgentCalls")

    static func record(
        _ stage: String, callID: UUID?, hostID: UUID?, detail: String, error: Error?
    ) {
        let entry = AgentCallDiagnostic(
            ts: .now, uptime: ProcessInfo.processInfo.systemUptime,
            processID: ProcessInfo.processInfo.processIdentifier,
            callId: callID, hostId: hostID, stage: stage, detail: detail,
            failure: error.map(AgentCallFailure.init)
        )
        let call = callID?.uuidString.lowercased() ?? "unknown"
        let failure = entry.failure.map { "\($0.domain):\($0.code) \($0.reason)" } ?? "none"
        logger.notice("call=\(call) stage=\(stage) detail=\(detail) failure=\(failure)")
        Task {
            do { try await DiagnosticsOutbox.shared.enqueue(line: entry.encodedLine(), kind: "call") }
            catch { logger.error("Call diagnostic could not persist call=\(call): \(error.localizedDescription)") }
        }
    }
}
