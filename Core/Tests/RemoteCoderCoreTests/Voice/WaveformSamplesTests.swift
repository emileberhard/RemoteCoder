import Foundation
import Testing
@testable import RemoteCoderCore

struct WaveformSamplesTests {
    @Test func aLongRecordingKeepsOnlyABoundedVisibleHistory() {
        var samples = WaveformSamples()
        for _ in 0..<20_000 { samples.append(0.5) }
        #expect(samples.values.count == 140)
        #expect(samples.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(abs((samples.values.last ?? 0) - 0.5) < 0.001)
    }

    @Test func invalidLevelsCannotProduceInvalidDrawingGeometry() {
        var samples = WaveformSamples()
        for level: Float in [.nan, .infinity, -.infinity, -2, 3, 0] { samples.append(level) }
        #expect(samples.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }
}
