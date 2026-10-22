import Testing
@testable import RemoteCoderCore

struct InterfaceZoomLevelTests {
    @Test func zoomingWalksTheLadderAndStopsAtBothEnds() {
        var level = InterfaceZoomLevel.actualSize
        var visited = [level.scale]
        while let next = level.zoomedIn {
            level = next
            visited.append(level.scale)
        }
        #expect(visited == [1, 1.1, 1.25, 1.5, 1.75, 2])

        while let next = level.zoomedOut { level = next }
        #expect(level.scale == 0.8)
        #expect(level.zoomedOut == nil)
    }

    @Test func storedScalesSnapToTheNearestStep() {
        #expect(InterfaceZoomLevel(storedScale: 1.3).scale == 1.25)
        #expect(InterfaceZoomLevel(storedScale: 5).scale == 2)
        #expect(InterfaceZoomLevel(storedScale: 0).scale == 0.8)
        #expect(InterfaceZoomLevel(storedScale: .nan) == .actualSize)
        #expect(InterfaceZoomLevel(storedScale: 1).isActualSize)
    }
}
