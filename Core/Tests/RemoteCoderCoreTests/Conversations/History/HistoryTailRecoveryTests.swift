import Testing
@testable import RemoteCoderCore

struct HistoryTailRecoveryTests {
    @Test func anUnavailableOpeningRetainsTheTailRequestUntilItLoads() {
        var recovery = HistoryTailRecovery()
        recovery.request(.reload)
        #expect(recovery.pending == .reload)
        recovery.loaded()
        #expect(recovery.pending == nil)
    }

    @Test func aLatestRequestSurvivesOtherReloadsAndClearsOnlyWhenTheTailLoads() {
        var recovery = HistoryTailRecovery()
        recovery.request(.latest)
        recovery.request(.reload)
        #expect(recovery.pending == .latest)
        recovery.loaded()
        #expect(recovery.pending == nil)
        recovery.request(.reload)
        #expect(recovery.pending == .reload)
        recovery.reset()
        #expect(recovery.pending == nil)
    }
}
