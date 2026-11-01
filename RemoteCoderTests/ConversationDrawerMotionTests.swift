import CoreGraphics
import Testing
@testable import RemoteCoder

@MainActor
struct ConversationDrawerMotionTests {
    @Test(arguments: [
        (0.45, 0, false), (0.55, 0, true), (0.1, 1, false),
        (0.2, 5, true), (0.8, -5, false), (0.12, 1.5, true), (0.88, -1.5, false),
    ] as [(CGFloat, CGFloat, Bool)])
    func aReleaseRestsOnTheSideItsVelocityCarriesItTo(progress: CGFloat, velocity: CGFloat, restsOpen: Bool) {
        #expect(DrawerMotion.restsOpen(progress: progress, velocity: velocity) == restsOpen)
    }

    @Test func grabbingDuringASettleContinuesFromTheCurrentPosition() {
        let motion = DrawerMotion(isOpen: false)
        motion.move(open: true, animated: true)
        motion.beginTracking()
        motion.track(by: 0.25)
        #expect(motion.progress == 0.25)
        #expect(motion.release(velocity: 0) == false)
    }

    @Test func aProgrammaticRequestEndsTheDragItInterrupts() {
        let motion = DrawerMotion(isOpen: false)
        motion.beginTracking()
        motion.track(by: 0.3)
        motion.move(open: false, animated: false)
        motion.track(by: 0.6)
        #expect(motion.progress == 0)
        #expect(motion.release(velocity: 10) == nil)
    }

    @Test func trackingStaysWithinTheDrawerRange() {
        let motion = DrawerMotion(isOpen: true)
        motion.beginTracking()
        motion.track(by: 2)
        #expect(motion.progress == 1)
        motion.track(by: -3)
        #expect(motion.progress == 0)
    }

    @Test(arguments: [
        (false, true, 0.6, true), (true, false, 0.4, true),
        (false, false, 0.4, false), (true, true, 0.6, false),
        (false, true, 1, false), (true, false, 0, false),
    ] as [(Bool, Bool, CGFloat, Bool)])
    func aDragOnlyTicksWhenAnInteriorReleaseChangesItsDestination(
        initialOpen: Bool, destinationOpen: Bool, progress: CGFloat, plays: Bool
    ) {
        var haptics = DrawerDragHaptics()
        haptics.begin(open: initialOpen)
        #expect(haptics.release(open: destinationOpen, progress: progress) == (plays ? .selection : nil))
        #expect(haptics.release(open: destinationOpen, progress: progress) == nil)
    }

    @Test func cancelledAndInterruptedDragsNeverReplayFeedback() {
        var haptics = DrawerDragHaptics()
        haptics.begin(open: false)
        haptics.cancel()
        #expect(haptics.release(open: true, progress: 0.6) == nil)
        haptics.begin(open: true)
        #expect(haptics.release(open: false, progress: 0.4) == .selection)
    }
}
