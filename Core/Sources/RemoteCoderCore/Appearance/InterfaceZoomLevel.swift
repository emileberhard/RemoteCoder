import Foundation

struct InterfaceZoomLevel: Equatable, Sendable {
    static let scales: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    static let actualSize = InterfaceZoomLevel(step: 2)

    private let step: Int

    private init(step: Int) {
        self.step = step
    }

    init(storedScale: Double) {
        guard storedScale.isFinite else {
            self = .actualSize
            return
        }
        let nearest = Self.scales.indices.min { abs(Self.scales[$0] - storedScale) < abs(Self.scales[$1] - storedScale) }
        self.init(step: nearest ?? Self.actualSize.step)
    }

    var scale: Double { Self.scales[step] }
    var isActualSize: Bool { self == .actualSize }

    var zoomedIn: InterfaceZoomLevel? {
        step + 1 < Self.scales.count ? InterfaceZoomLevel(step: step + 1) : nil
    }

    var zoomedOut: InterfaceZoomLevel? {
        step > 0 ? InterfaceZoomLevel(step: step - 1) : nil
    }
}
