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

    @Test func frameTicksBetweenSamplesGlideWithoutSampling() {
        let trace = WaveformTrace()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var reads = 0
        let level: () -> Float = { reads += 1; return 1 }

        #expect(trace.advance(to: start, every: .milliseconds(25), level: level) == 0)
        #expect(reads == 1)
        let midway = trace.advance(to: start.addingTimeInterval(0.010), every: .milliseconds(25), level: level)
        #expect(abs(midway - 0.4) < 0.001)
        #expect(reads == 1)

        let afterTwoSamples = trace.advance(to: start.addingTimeInterval(0.060), every: .milliseconds(25), level: level)
        #expect(abs(afterTwoSamples - 0.4) < 0.001)
        #expect(reads == 2)
        #expect(trace.samples.values.count == 123)
    }

    @Test func resumingAfterAPauseRestartsTheClockInsteadOfBackfilling() {
        let trace = WaveformTrace()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        _ = trace.advance(to: start, every: .milliseconds(25), level: { 0.5 })
        let resumed = trace.advance(to: start.addingTimeInterval(5), every: .milliseconds(25), level: { 0.5 })
        #expect(resumed == 0)
        #expect(trace.samples.values.count == 122)
    }

    @Test func invalidLevelsCannotProduceInvalidDrawingGeometry() {
        var samples = WaveformSamples()
        for level: Float in [.nan, .infinity, -.infinity, -2, 3, 0] { samples.append(level) }
        #expect(samples.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }
}
