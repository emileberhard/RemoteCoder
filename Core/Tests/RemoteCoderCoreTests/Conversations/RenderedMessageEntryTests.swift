import Observation
import Synchronization
import Testing
@testable import RemoteCoderCore

@MainActor
struct RenderedMessageEntryTests {
    @Test func readingFramePresenceIgnoresPayloadRevisionsAndObservesArrivalAndEviction() {
        let entry = RenderedMessageEntry<String>()
        let presenceChanges = Mutex(0)
        withObservationTracking { _ = entry.isPresent } onChange: { presenceChanges.withLock { $0 += 1 } }
        entry.replace(with: "First presentation")
        #expect(entry.isPresent)
        #expect(presenceChanges.withLock { $0 } == 1)
        let payloadChanges = Mutex(0)
        withObservationTracking { _ = entry.isPresent } onChange: { presenceChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = entry.rendered } onChange: { payloadChanges.withLock { $0 += 1 } }
        for revision in 1...20 { entry.replace(with: "Streaming revision \(revision)") }
        #expect(presenceChanges.withLock { $0 } == 1)
        #expect(payloadChanges.withLock { $0 } == 1)
        #expect(entry.rendered == "Streaming revision 20")
        entry.replace(with: nil)
        #expect(!entry.isPresent)
        #expect(presenceChanges.withLock { $0 } == 2)
    }
}
