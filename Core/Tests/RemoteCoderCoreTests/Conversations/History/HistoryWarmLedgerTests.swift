import Testing
@testable import RemoteCoderCore

struct HistoryWarmLedgerTests {
    @Test func unavailablePreparationPreservesCompletedVisualCoverageForTheSameRevision() {
        var ledger = HistoryWarmLedger()
        let context = HTMLVisualPreparationContext(width: 320,
            theme: HTMLVisualTheme(fontSize: 17, text: "#000", secondaryText: "#333", background: "#fff",
                surface: "#eee", accent: "#00f", isDark: false))
        let observation = ledger.observation(threadID: "t", revision: 1)
        ledger.succeeded(threadID: "t", observation: observation, context: context)
        #expect(!ledger.needsWarm(threadID: "t", revision: 1, context: nil))
        ledger.succeeded(threadID: "t", observation: observation, context: nil)
        #expect(!ledger.needsWarm(threadID: "t", revision: 1, context: context))

        ledger.changed("t")
        ledger.succeeded(threadID: "t", observation: ledger.observation(threadID: "t", revision: 1), context: nil)
        #expect(ledger.needsWarm(threadID: "t", revision: 1, context: context))
    }

    @Test func evictedHistoryCoverageCannotSatisfyALaterRead() {
        var ledger = HistoryWarmLedger()
        #expect(ledger.readCovers(threadID: "old", revision: 1) != true)
        let original = ledger.observation(threadID: "old", revision: 1)
        ledger.succeeded(threadID: "old", observation: original, context: nil)
        #expect(ledger.readCovers(threadID: "old", revision: 1) == true)
        for index in 0..<ConversationHeaderRetention.countLimit {
            if index == ConversationHeaderRetention.countLimit - 1 {
                #expect(ledger.readCovers(threadID: "old", revision: 1) == true)
            }
            let thread = "thread-\(index)"
            ledger.succeeded(threadID: thread, observation: ledger.observation(threadID: thread, revision: 1), context: nil)
        }
        #expect(ledger.needsWarm(threadID: "old", revision: 1, context: nil))
        #expect(ledger.readCovers(threadID: "old", revision: 1) != true)
        #expect(ledger.observation(threadID: "old", revision: 1) != original)
        ledger.readSucceeded(threadID: "old", observation: original)
        #expect(ledger.readCovers(threadID: "old", revision: 1) != true)
        let current = ledger.observation(threadID: "old", revision: 1)
        ledger.readSucceeded(threadID: "old", observation: current)
        #expect(ledger.readCovers(threadID: "old", revision: 1) == true)
        ledger.changed("old")
        ledger.readSucceeded(threadID: "old", observation: current)
        #expect(ledger.readCovers(threadID: "old", revision: 1) != true)
        ledger.readSucceeded(threadID: "old", observation: ledger.observation(threadID: "old", revision: 1))
        #expect(ledger.readCovers(threadID: "old", revision: 1) == true)
        #expect(ledger.readCovers(threadID: "old", revision: 2) == false)
    }

    @Test func unchangedWarmAndChangesDuringWarmHaveDistinctCoverage() {
        var ledger = HistoryWarmLedger()
        ledger.changed("t")
        let first = ledger.observation(threadID: "t", revision: 1)
        #expect(ledger.needsWarm(threadID: "t", revision: 1, context: nil))
        ledger.succeeded(threadID: "t", observation: first, context: nil)
        #expect(!ledger.needsWarm(threadID: "t", revision: 1, context: nil))
        ledger.changed("t")
        let second = ledger.observation(threadID: "t", revision: 1)
        ledger.changed("t")
        ledger.succeeded(threadID: "t", observation: second, context: nil)
        #expect(ledger.needsWarm(threadID: "t", revision: 1, context: nil))
        ledger.succeeded(threadID: "t", observation: ledger.observation(threadID: "t", revision: 1), context: nil)
        #expect(!ledger.needsWarm(threadID: "t", revision: 1, context: nil))
        #expect(ledger.needsWarm(threadID: "t", revision: 2, context: nil))
    }

    @Test func invalidationAndClearingEndEarlierObservations() {
        var ledger = HistoryWarmLedger()
        let beforeInvalidation = ledger.observation(threadID: "t", revision: 0)
        ledger.invalidate("t")
        #expect(ledger.observation(threadID: "t", revision: 0) != beforeInvalidation)
        let other = ledger.observation(threadID: "u", revision: 0)
        #expect(ledger.observation(threadID: "u", revision: 0) == other)

        let beforeClear = ledger.observation(threadID: "u", revision: 0)
        ledger.clear()
        #expect(ledger.observation(threadID: "u", revision: 0) != beforeClear)
        #expect(ledger.observation(threadID: "t", revision: 0) != beforeInvalidation)
    }
}
