import Testing
@testable import RemoteCoderCore

@MainActor
struct TargetPreparationTests {
    @Test func quiescingResetsPreparedLifetimesForKeepOpenWithoutRevivingRetiredTargets() async {
        let preparation = TargetPreparation()
        var listeners = 0
        await preparation.prepare { listeners += 1 }
        #expect(preparation.quiesce().isEmpty)
        #expect(!preparation.isPrepared)
        await preparation.prepare { listeners += 1 }
        #expect(listeners == 2)
        _ = preparation.retire()
        _ = preparation.quiesce()
        await preparation.prepare { listeners += 1 }
        #expect(listeners == 2)
    }
    @Test func aSecondSelectionDoesNotBootstrapTheTargetAgain() async {
        let preparation = TargetPreparation()
        var bootstraps = 0
        await preparation.prepare { bootstraps += 1 }
        await preparation.prepare { bootstraps += 1 }
        #expect(bootstraps == 1)
        #expect(preparation.isPrepared)
    }

    @Test func aRetiredTargetDoesNotPrepareAndAReplacementPreparesIndependently() async {
        let preparation = TargetPreparation()
        var bootstraps = 0
        _ = preparation.retire()
        await preparation.prepare { bootstraps += 1 }
        #expect(bootstraps == 0)
        #expect(!preparation.isPrepared)
        let replacement = TargetPreparation()
        await replacement.prepare { bootstraps += 1 }
        #expect(bootstraps == 1)
        #expect(replacement.isPrepared)
    }

    @Test func concurrentPreparationJoinsAndRetirementRejectsTheHeldCompletion() async throws {
        let preparation = TargetPreparation()
        let started = AsyncStream<Void>.makeStream()
        let joined = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var bootstraps = 0
        var firstFinished = false
        var secondFinished = false
        let first = Task {
            await preparation.prepare {
                bootstraps += 1
                await withCheckedContinuation {
                    release = $0
                    started.continuation.yield(())
                }
            }
            firstFinished = true
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let second = Task {
            joined.continuation.yield(())
            await preparation.prepare { bootstraps += 1 }
            secondFinished = true
        }
        var joins = joined.stream.makeAsyncIterator()
        _ = await joins.next()
        #expect(!firstFinished)
        #expect(!secondFinished)
        #expect(bootstraps == 1)

        let retired = preparation.retire()
        #expect(retired.count == 1)
        #expect(retired.allSatisfy { $0.isCancelled })
        try #require(release).resume()
        await first.value
        await second.value
        await preparation.prepare { bootstraps += 1 }
        #expect(bootstraps == 1)
        #expect(!preparation.isPrepared)
        started.continuation.finish()
        joined.continuation.finish()
    }
}
