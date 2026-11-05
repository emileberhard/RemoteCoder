import Testing

@testable import RemoteCoderCore

struct TargetLifecycleTests {
    private func lifecycle(work: Int = 0, presented: Bool = true, voice: Bool = false) -> TargetLifecycle {
        var lifecycle = TargetLifecycle()
        _ = lifecycle.handle(.presentation(TargetPresentation(presented: presented)))
        _ = lifecycle.handle(.activeWorkChanged(count: work))
        _ = lifecycle.handle(.voiceCall(voice))
        return lifecycle
    }

    @Test func aPresentedTargetRefreshesOnActivation() {
        var life = lifecycle()

        let effects = life.handle(.appPhase(.active))

        #expect(effects == [.startLoops, .refreshForeground(generation: 1)])
        #expect(life.foreground == .current)
    }

    @Test func aHiddenIdleTargetDefersItsRefreshUntilItIsPresented() {
        var life = lifecycle(presented: false)

        #expect(life.handle(.appPhase(.active)) == [.startLoops])
        #expect(life.foreground == .deferred)
        #expect(life.handle(.presentation(TargetPresentation(presented: true))) == [.refreshForeground(generation: 1)])
        #expect(life.foreground == .current)
    }

    @Test func aHostPreparedWhileHiddenAndIdleDefersItsRefreshUntilItIsPresented() {
        var life = lifecycle(presented: false)

        #expect(life.handle(.hostPrepared) == [])
        #expect(life.foreground == .deferred)
        #expect(life.handle(.presentation(TargetPresentation(presented: true))) == [.refreshForeground(generation: 0)])

        var visible = lifecycle()
        _ = visible.handle(.hostPrepared)
        #expect(visible.foreground == .current)
    }

    @Test func aHiddenTargetWithWorkOrAnOpenDrawerStillRefreshesOnActivation() {
        var busy = lifecycle(work: 1, presented: false)
        #expect(busy.handle(.appPhase(.active)).contains(.refreshForeground(generation: 1)))

        var drawer = lifecycle(presented: false)
        _ = drawer.handle(.presentation(TargetPresentation(presented: false, drawerOpen: true)))
        #expect(drawer.handle(.appPhase(.active)).contains(.refreshForeground(generation: 1)))
    }

    @Test func aDeferredRefreshDoesNotStartWhileBackgrounded() {
        var life = lifecycle(presented: false)
        _ = life.handle(.appPhase(.active))
        _ = life.handle(.appPhase(.background))

        #expect(life.handle(.presentation(TargetPresentation(presented: true))) == [])
        #expect(life.foreground == .deferred)
    }

    @Test func backgroundingAnIdleTargetDisconnectsAtOnce() {
        var life = lifecycle()

        let effects = life.handle(.appPhase(.background))

        #expect(effects == [.flush, .stopLoops, .disconnect])
        #expect(life.hold == .disconnected)
        #expect(!life.allowsActivityReads)
    }

    @Test func backgroundingABusyTargetHoldsGrace() {
        var life = lifecycle(work: 1)

        let effects = life.handle(.appPhase(.background))

        #expect(effects == [.flush, .stopLoops, .beginGrace])
        #expect(life.hold == .grace)
    }

    @Test func graceExpiryDisconnectsOnceAndALateExpiryIsSilent() {
        var life = lifecycle(work: 1)
        _ = life.handle(.appPhase(.background))

        #expect(life.handle(.graceExpired) == [.disconnect])
        #expect(life.hold == .disconnected)
        #expect(life.handle(.graceExpired) == [])
    }

    @Test func workEndingDuringGraceDisconnectsAtOnce() {
        var life = lifecycle(work: 2)
        _ = life.handle(.appPhase(.background))

        #expect(life.handle(.activeWorkChanged(count: 1)).isEmpty)
        #expect(life.hold == .grace)
        #expect(life.handle(.activeWorkChanged(count: 0)) == [.disconnect])
    }

    @Test func workStartingWhileDisconnectedInTheBackgroundStartsANewGrace() {
        var life = lifecycle()
        _ = life.handle(.appPhase(.background))

        #expect(life.handle(.activeWorkChanged(count: 1)) == [.beginGrace])
        #expect(life.hold == .grace)
    }

    @Test func aVoiceCallKeepsTheConnectionThroughBackgroundingAndDisconnectsWhenItEnds() {
        var life = lifecycle(work: 1, voice: true)

        let effects = life.handle(.appPhase(.background))

        #expect(effects == [.flush, .stopLoops])
        #expect(life.hold == .none)
        #expect(life.allowsActivityReads)
        #expect(life.handle(.voiceCall(false)) == [.disconnect])
    }

    @Test func aVoiceCallStartingDuringGraceReleasesTheHold() {
        var life = lifecycle(work: 1)
        _ = life.handle(.appPhase(.background))

        #expect(life.handle(.voiceCall(true)) == [.endGrace])
        #expect(life.hold == .none)
        #expect(life.handle(.graceExpired) == [])
    }

    @Test func aVoiceCallEndingInTheForegroundDisconnectsNothing() {
        var life = lifecycle(voice: true)

        #expect(life.handle(.voiceCall(false)) == [])
    }

    @Test func inactiveWithoutWorkOnlyStopsLoops() {
        var life = lifecycle()

        #expect(life.handle(.appPhase(.inactive)) == [.stopLoops])
        #expect(!life.isBackgrounded)
        #expect(life.hold == .none)
    }

    @Test func inactiveWithWorkHoldsTheAssertionWithoutAGraceTimer() {
        var life = lifecycle(work: 1)

        #expect(life.handle(.appPhase(.inactive)) == [.stopLoops, .holdAssertion])
        #expect(life.hold == .assertion)
        #expect(life.isBackgrounded)
        #expect(life.handle(.appPhase(.inactive)) == [.stopLoops])
    }

    @Test func backgroundingAfterAnInactiveHoldStartsTheGraceTimer() {
        var life = lifecycle(work: 1)
        _ = life.handle(.appPhase(.inactive))

        #expect(life.handle(.appPhase(.background)) == [.flush, .stopLoops, .beginGrace])
        #expect(life.hold == .grace)
    }

    @Test func anAssertionExpiryDisconnects() {
        var life = lifecycle(work: 1)
        _ = life.handle(.appPhase(.inactive))

        #expect(life.handle(.graceExpired) == [.disconnect])
    }

    @Test func returningToActiveReleasesTheHoldAndRefreshesUnderANewGeneration() {
        var life = lifecycle(work: 1)
        _ = life.handle(.appPhase(.background))

        let effects = life.handle(.appPhase(.active))

        #expect(effects == [.endGrace, .startLoops, .refreshForeground(generation: 2)])
        #expect(life.hold == .none)
        #expect(!life.isBackgrounded)
    }

    @Test func aDisconnectedTargetReconnectsThroughTheForegroundRefresh() {
        var life = lifecycle()
        _ = life.handle(.appPhase(.background))

        let effects = life.handle(.appPhase(.active))

        #expect(effects == [.startLoops, .refreshForeground(generation: 2)])
        #expect(life.hold == .none)
    }

    @Test func everyAppPhaseChangeStartsANewGenerationAndNothingElseDoes() {
        var life = lifecycle()
        let start = life.generation

        _ = life.handle(.presentation(TargetPresentation(presented: false, drawerOpen: true)))
        _ = life.handle(.activeWorkChanged(count: 3))
        _ = life.handle(.voiceCall(true))
        #expect(life.generation == start)

        _ = life.handle(.appPhase(.inactive))
        _ = life.handle(.appPhase(.background))
        #expect(life.generation == start + 2)
        #expect(!life.isCurrent(start))
        #expect(life.isCurrent(start + 2))
    }

    @Test func aRetiredTargetIgnoresEveryLaterEventAndItsGenerationIsNoLongerCurrent() {
        var life = lifecycle(work: 1)
        _ = life.handle(.appPhase(.background))
        let generation = life.generation

        #expect(life.handle(.retire) == [.flush, .stopLoops, .endGrace])
        #expect(life.isRetired)
        #expect(!life.isCurrent(generation))
        #expect(life.handle(.activeWorkChanged(count: 0)) == [])
        #expect(life.handle(.voiceCall(false)) == [])
        #expect(life.handle(.graceExpired) == [])
        #expect(life.handle(.appPhase(.active)) == [])
        #expect(life.handle(.retire) == [])
        #expect(!life.allowsActivityReads)
    }

    @Test func aRetiredTargetIsNeverOnScreen() {
        var life = lifecycle()
        #expect(life.isOnScreen)

        _ = life.handle(.retire)

        #expect(!life.isOnScreen)
    }

    @Test func aTargetIsOnScreenOnlyWhilePresentedAndActive() {
        var life = lifecycle(presented: false)
        #expect(!life.isOnScreen)

        _ = life.handle(.presentation(TargetPresentation(presented: true)))
        #expect(life.isOnScreen)

        _ = life.handle(.appPhase(.inactive))
        #expect(!life.isOnScreen)
    }

    @Test(arguments: [
        (true, true, false),
        (false, false, false),
        (true, false, true),
        (false, true, false),
    ])
    func aDisconnectNeedsTheBackgroundAndNoVoiceCall(isBackground: Bool, voice: Bool, allowed: Bool) {
        var life = lifecycle(voice: voice)
        if isBackground { _ = life.handle(.appPhase(.background)) }

        #expect(life.allowsDisconnect == allowed)
        #expect(life.allowsActivityReads == !allowed)
    }
    @Test func quitQuiescingRejectsLateEventsAndKeepOpenUsesNormalActivation() {
        var life = lifecycle(work: 1)
        let prior = life.generation
        #expect(life.handle(.quiesce) == [.stopLoops])
        #expect(!life.acceptsWork)
        #expect(!life.isRetired)
        #expect(!life.isCurrent(prior))
        #expect(life.handle(.appPhase(.active)).isEmpty)
        #expect(life.handle(.presentation(TargetPresentation())).isEmpty)
        let resumed = life.handle(.resume)
        #expect(life.acceptsWork)
        #expect(life.isSceneLive)
        #expect(resumed.contains(.startLoops))
        #expect(resumed.contains(.refreshForeground(generation: life.generation)))
        #expect(life.isCurrent(life.generation))
        _ = life.handle(.retire)
        #expect(life.handle(.resume).isEmpty)
        #expect(life.isRetired)
    }

}
