import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct TerminationDrainTests {
    @Test(.timeLimit(.minutes(1))) func aHeldDrainOffersPendingPresentationWithoutReleasingOrDuplicatingTheOperation() async throws {
        var release: CheckedContinuation<[String], Never>?
        var admissions = 0
        let drain = TerminationDrain {
            admissions += 1
            return await withCheckedContinuation { release = $0 }
        }
        #expect(await drain.presentation(after: .milliseconds(10)) == .pending)
        #expect(admissions == 1)
        #expect(await drain.presentation(after: .milliseconds(10)) == .pending)
        #expect(admissions == 1)
        try #require(release).resume(returning: ["Draft save failed"])
        #expect(await drain.drain() == ["Draft save failed"])
        #expect(await drain.presentation(after: .seconds(1)) == .finished(["Draft save failed"]))
    }

    @Test func aCompletedDrainPresentsItsFailuresWithoutWaitingForTheDeadline() async {
        let drain = TerminationDrain { ["MacBook: Checkpoint save failed"] }
        #expect(await drain.presentation(after: .seconds(10)) == .finished(["MacBook: Checkpoint save failed"]))
    }
}
