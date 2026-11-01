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
        #expect(DrawerDragHaptics.event(initialOpen: initialOpen, open: destinationOpen, progress: progress) == (plays ? .selection : nil))
    }
}
