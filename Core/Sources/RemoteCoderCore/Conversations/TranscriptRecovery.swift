import Foundation
import OSLog

@MainActor
protocol TranscriptRecoverySource: AnyObject {
    func reconciliationKey(sessionID: String) -> TranscriptRecovery.ReconciliationKey
    func applyReconciledHistory(sessionID: String, source: String) async throws
    func applyInputDeliveryEvidence(sessionID: String) async throws
    func trackedTurnID(forThread threadID: String) -> String?
}

@MainActor
final class TranscriptRecovery {
    struct ReconciliationKey: Equatable {
        let sessionID: String
        let identity: String
        let scenePhase: Int
        let observation: HistoryWarmLedger.Observation
    }

    private enum Reconciliation {
        case running(ReconciliationKey, Task<Bool, Never>)
        case reconciled(ReconciliationKey)
    }

    private static let foregroundRefreshInterval: TimeInterval = 2

    private weak var source: (any TranscriptRecoverySource)?
    private let logger = Logger(subsystem: "RemoteCoder", category: "TranscriptRecovery")
    private var marks: [String: String] = [:]
    private var recovering: Set<String> = []
    private var reconciliation: Reconciliation?
    private var lastForegroundRefresh: Date?

    init(source: any TranscriptRecoverySource) {
        self.source = source
    }

    var markCount: Int { marks.count }

    func mark(sessionID: String, turnID: String) {
        logger.notice("markTranscriptRefreshNeeded session=\(sessionID, privacy: .public) turn=\(turnID, privacy: .public)")
        marks[sessionID] = GatewayNotificationRouting.normalizeTurnID(turnID)
    }

    func awaitsCompletion(ofNormalizedTurn turnID: String, sessionID: String) -> Bool {
        marks[sessionID] == turnID
    }

    func forget(sessionID: String) {
        marks.removeValue(forKey: sessionID)
    }

    func invalidateForegroundRefresh() {
        lastForegroundRefresh = nil
    }

    func recoverAfterDisconnect(sessionID: String) async {
        guard recovering.insert(sessionID).inserted else { return }
        defer { recovering.remove(sessionID) }
        guard let turnID = marks[sessionID] else { return }
        guard await reconcile(sessionID: sessionID, source: "reconnect") else { return }
        let trackedTurnID = source?.trackedTurnID(forThread: sessionID).map(GatewayNotificationRouting.normalizeTurnID)
        if trackedTurnID != turnID { marks.removeValue(forKey: sessionID) }
    }

    func refreshOnForeground(sessionID: String, stillPresenting: @MainActor () -> Bool) async {
        if let last = lastForegroundRefresh, Date().timeIntervalSince(last) < Self.foregroundRefreshInterval { return }
        if await reconcile(sessionID: sessionID, source: "foreground"), stillPresenting() {
            lastForegroundRefresh = .now
        }
    }

    func reconcileInputDelivery(sessionID: String) async {
        guard let source else { return }
        do {
            try await source.applyInputDeliveryEvidence(sessionID: sessionID)
        } catch {
            logger.notice("Input delivery reconciliation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reconcile(sessionID: String, source reason: String) async -> Bool {
        while true {
            guard let source else { return false }
            let key = source.reconciliationKey(sessionID: sessionID)
            switch reconciliation {
            case .reconciled(let reconciled) where reconciled == key:
                return true
            case .running(let running, let task):
                let succeeded = await task.value
                if running == key { return succeeded }
            case .reconciled, nil:
                let task = Task { [weak self] () -> Bool in
                    guard let self, let source = self.source else { return false }
                    let succeeded: Bool
                    do {
                        try await source.applyReconciledHistory(sessionID: sessionID, source: reason)
                        succeeded = true
                    } catch {
                        self.logger.notice("Transcript reconciliation failed source=\(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        succeeded = false
                    }
                    if case .running(let current, _) = self.reconciliation, current == key {
                        self.reconciliation = succeeded ? .reconciled(key) : nil
                    }
                    return succeeded
                }
                reconciliation = .running(key, task)
                return await task.value
            }
        }
    }
}
