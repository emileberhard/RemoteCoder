import Testing
@testable import RemoteCoderCore

@MainActor
struct TranscriptRecoveryTests {
    @Test func deliveryChecksAlwaysReadFreshEvidenceAndDoNotCoverTranscriptRecovery() async {
        let source = RecoverySource()
        let recovery = TranscriptRecovery(source: source)
        await recovery.reconcileInputDelivery(sessionID: "thread")
        #expect(source.deliveryReads == 1)
        #expect(source.historyReads == 0)
        #expect(await recovery.reconcile(sessionID: "thread", source: "foreground"))
        #expect(source.historyReads == 1)
        await recovery.reconcileInputDelivery(sessionID: "thread")
        #expect(source.deliveryReads == 2)
        #expect(await recovery.reconcile(sessionID: "thread", source: "reconnect"))
        #expect(source.historyReads == 1)
    }
}

@MainActor
private final class RecoverySource: TranscriptRecoverySource {
    var historyReads = 0
    var deliveryReads = 0

    func reconciliationKey(sessionID: String) -> TranscriptRecovery.ReconciliationKey {
        .init(sessionID: sessionID, identity: "shown", scenePhase: 0,
              observation: .init(revision: 0, epoch: 0, change: 0))
    }

    func applyReconciledHistory(sessionID: String, source: String) async throws {
        historyReads += 1
    }

    func applyInputDeliveryEvidence(sessionID: String) async throws {
        deliveryReads += 1
    }

    func trackedTurnID(forThread threadID: String) -> String? { nil }
}
