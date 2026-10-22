import Foundation
import Testing
@testable import RemoteCoderCore

struct RealtimeVoiceLifecycleTests {
    @Test func transcriptTailCannotReactivateAStoppedCall() throws {
        var lifecycle = RealtimeVoiceLifecycle()
        let call = try startCall(&lifecycle)
        let connection = try connect(&lifecycle, call: call, reconnecting: false)
        lifecycle.update(.speaking, connectionID: connection)

        let stoppingCall = lifecycle.beginStop()
        #expect(stoppingCall == call)
        #expect(lifecycle.ownsConnection(connection))
        lifecycle.update(.listening, connectionID: connection)
        #expect(lifecycle.state == .stopping)
        #expect(!lifecycle.isActive)

        lifecycle.finishStop(callID: call, finalState: .idle)
        lifecycle.update(.speaking, connectionID: connection)
        #expect(lifecycle.state == .idle)
        let nextCall = lifecycle.start(callID: UUID())
        #expect(nextCall)
    }

    @Test func newCallWaitsForCleanupAndIgnoresOldCompletion() throws {
        var lifecycle = RealtimeVoiceLifecycle()
        let oldCall = try startCall(&lifecycle)
        _ = lifecycle.beginStop()
        let startDuringCleanup = lifecycle.start(callID: UUID())
        #expect(!startDuringCleanup)
        lifecycle.finishStop(callID: oldCall, finalState: .idle)

        let newCall = try startCall(&lifecycle)
        lifecycle.finishStop(callID: oldCall, finalState: .failed("old failure"))
        #expect(lifecycle.callID == newCall)
        #expect(lifecycle.state == .connecting)
        #expect(lifecycle.isActive)
    }

    @Test func oldPeerEventsCannotChangeTheReplacementConnection() throws {
        var lifecycle = RealtimeVoiceLifecycle()
        let call = try startCall(&lifecycle)
        let oldConnection = try connect(&lifecycle, call: call, reconnecting: false)
        let newConnection = try connect(&lifecycle, call: call, reconnecting: true)
        lifecycle.update(.listening, connectionID: oldConnection)
        #expect(lifecycle.state == .reconnecting)
        #expect(!lifecycle.ownsConnection(oldConnection))
        lifecycle.update(.listening, connectionID: newConnection)
        #expect(lifecycle.state == .listening)
    }

    @Test func cancelledStartupCannotCreateAnotherConnection() throws {
        var lifecycle = RealtimeVoiceLifecycle()
        let call = try startCall(&lifecycle)
        _ = lifecycle.beginStop()
        let connectDuringCleanup = lifecycle.beginConnection(callID: call, reconnecting: false)
        #expect(connectDuringCleanup == nil)
        lifecycle.finishStop(callID: call, finalState: .idle)
        _ = lifecycle.start(callID: UUID())
        let connectAfterReplacement = lifecycle.beginConnection(callID: call, reconnecting: false)
        #expect(connectAfterReplacement == nil)
    }

    @Test func failedCallsCanBeStartedAgainWithoutRestartingTheApp() throws {
        var lifecycle = RealtimeVoiceLifecycle()
        let call = try startCall(&lifecycle)
        _ = lifecycle.beginStop()
        let duplicateStop = lifecycle.beginStop()
        #expect(duplicateStop == nil)
        lifecycle.finishStop(callID: call, finalState: .failed("network lost"))
        let restartedCall = lifecycle.start(callID: UUID())
        #expect(restartedCall)
        #expect(lifecycle.state == .connecting)
    }

    @Test func ringingCannotDisplaceAnOwnedCallOrRestartAfterHangup() {
        let ringingCall = UUID()
        let otherCall = UUID()
        var lifecycle = RealtimeVoiceLifecycle()
        let accepted = lifecycle.receiveIncoming(callID: ringingCall)
        #expect(accepted)
        #expect(lifecycle.state == .ringing)
        let displaced = lifecycle.receiveIncoming(callID: otherCall)
        #expect(!displaced)
        #expect(lifecycle.callID == ringingCall)
        let outgoing = lifecycle.start(callID: otherCall)
        #expect(!outgoing)
        let stopped = lifecycle.beginStop()
        #expect(stopped == ringingCall)
        let staleConnection = lifecycle.beginConnection(callID: ringingCall, reconnecting: false)
        #expect(staleConnection == nil)
        let whileStopping = lifecycle.receiveIncoming(callID: otherCall)
        #expect(!whileStopping)
        lifecycle.finishStop(callID: ringingCall, finalState: .idle)
        let next = lifecycle.receiveIncoming(callID: otherCall)
        #expect(next)
        let oldCall = lifecycle.beginConnection(callID: ringingCall, reconnecting: false)
        #expect(oldCall == nil)
    }

    private func startCall(_ lifecycle: inout RealtimeVoiceLifecycle) throws -> UUID {
        let call = UUID()
        let started = lifecycle.start(callID: call)
        try #require(started)
        return call
    }

    private func connect(
        _ lifecycle: inout RealtimeVoiceLifecycle, call: UUID, reconnecting: Bool
    ) throws -> UUID {
        let connection = lifecycle.beginConnection(callID: call, reconnecting: reconnecting)
        return try #require(connection)
    }
}
