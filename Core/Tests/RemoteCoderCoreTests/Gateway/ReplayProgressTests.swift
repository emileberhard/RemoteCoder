import Foundation
import Testing
@testable import RemoteCoderCore

struct ReplayProgressTests {
    private struct Envelope: Decodable {
        let result: ReplayProgress.Page
    }

    @Test func fixturesContinueFromTheLastScannedSequence() throws {
        let first = try fixture("page-has-more")
        var progress = ReplayProgress(cursor: NotificationCursor(), afterSequence: 0)

        let firstStep = progress.complete(first)
        #expect(firstStep.hasMore)
        #expect(firstStep.gap == nil)
        #expect(progress.nextAfterSequence == 2)
        #expect(progress.cursor.sequence == 2)
        #expect(progress.cursor.epoch == first.epoch)

        let second = ReplayProgress.Page(epoch: first.epoch, throughSequence: 3,
            hasMore: false, evictedBefore: false, skipped: [])
        let secondStep = progress.complete(second)
        #expect(!secondStep.hasMore)
        #expect(secondStep.gap == nil)
        #expect(progress.cursor.sequence == 3)
        #expect(progress.nextAfterSequence == 3)
    }

    @Test func skippedFixtureMarksOnlyItsThreadForRecovery() throws {
        var progress = ReplayProgress(cursor: NotificationCursor(), afterSequence: 0)

        let step = progress.complete(try fixture("skipped"))

        #expect(step.gap == .threads(["thread-1"]))
        #expect(!step.hasMore)
        #expect(progress.cursor.sequence == 3)
    }

    @Test func changedEpochResetsTheCursorAndRequiresFullRecovery() throws {
        var cursor = NotificationCursor()
        cursor.adopt(epoch: "11111111-1111-4111-8111-111111111111")
        cursor.advance(to: 100)
        var progress = ReplayProgress(cursor: cursor, afterSequence: 100)

        let step = progress.complete(try fixture("epoch-reset"))

        #expect(step.gap == .allThreads)
        #expect(!step.hasMore)
        #expect(progress.cursor.sequence == 1)
        #expect(progress.cursor.epoch == "22222222-2222-4222-8222-222222222222")
    }

    @Test func eighthIncompletePageStopsAndRequiresFullRecovery() {
        var progress = ReplayProgress(cursor: NotificationCursor(), afterSequence: 0)
        for sequence in 1...ReplayProgress.pageLimit {
            let page = ReplayProgress.Page(epoch: "epoch", throughSequence: UInt64(sequence),
                hasMore: true, evictedBefore: false, skipped: [])
            let step = progress.complete(page)
            #expect(step.hasMore == (sequence < ReplayProgress.pageLimit))
            if sequence == ReplayProgress.pageLimit { #expect(step.gap == .allThreads) }
        }
        #expect(progress.cursor.sequence == UInt64(ReplayProgress.pageLimit))
    }

    private func fixture(_ name: String) throws -> ReplayProgress.Page {
        let data = try ProtocolFixtures.data(at: "replay/\(name).json")
        return try JSONDecoder().decode(Envelope.self, from: data).result
    }
}
