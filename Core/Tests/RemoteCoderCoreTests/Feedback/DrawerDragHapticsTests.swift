import Foundation
import Testing
@testable import RemoteCoderCore

struct DrawerDragHapticsTests {
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
        #expect(haptics.release(open: !initialOpen, progress: 0.5) == nil)
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
