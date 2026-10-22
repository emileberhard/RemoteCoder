import Testing
@testable import RemoteCoder

@MainActor
struct AttachmentFeedbackTests {
    @Test func mixedImageAndVideoStagingEmitsOneAggregateAcceptance() {
        var events: [HapticEvent] = []
        let batch = AttachmentFeedbackBatch(count: 3) { events.append($0) }
        batch.finish(.accepted)
        batch.finish(.accepted)
        #expect(events.isEmpty)
        batch.finish(.accepted)
        batch.finish(.accepted)
        #expect(events == [.commit])
    }

    @Test func partialFailureNeverClaimsSuccess() {
        var events: [HapticEvent] = []
        let batch = AttachmentFeedbackBatch(count: 2) { events.append($0) }
        batch.finish(.failed)
        #expect(events == [.error])
        batch.finish(.accepted)
        #expect(events == [.error])
    }

    @Test func laterUploadFailureIsDistinctAndReportedOncePerBatch() {
        var events: [HapticEvent] = []
        let batch = AttachmentFeedbackBatch(count: 1) { events.append($0) }
        batch.finish(.accepted)
        batch.uploadFailed()
        batch.uploadFailed()
        #expect(events == [.commit, .error])
    }

    @Test func cancelledBatchRemainsSilent() {
        var events: [HapticEvent] = []
        let batch = AttachmentFeedbackBatch(count: 2) { events.append($0) }
        batch.finish(.cancelled)
        batch.finish(.accepted)
        #expect(events.isEmpty)
    }
}
