import Foundation
import Testing
@testable import RemoteCoderCore

struct NotificationCursorTests {
    @Test func storesEpochWithSequenceAndResetsOnEpochChange() {
        var cursor = NotificationCursor()
        let adoptedFirst = cursor.adopt(epoch: "first")
        #expect(!adoptedFirst)
        cursor.advance(to: 12)
        #expect(cursor.epoch == "first")
        let readoptedFirst = cursor.adopt(epoch: "first")
        #expect(!readoptedFirst)
        #expect(cursor.sequence == 12)

        let adoptedSecond = cursor.adopt(epoch: "second")
        #expect(adoptedSecond)
        #expect(cursor.epoch == "second")
        #expect(cursor.sequence == nil)
        cursor.advance(to: 1)
        #expect(cursor.sequence == 1)
    }

    @Test(arguments: [
        (nil, nil, "gateway", 40), ("gateway", 55, "gateway", 55), ("gateway", 12, "gateway", 40),
        ("restarted", 900, "gateway", 40),
    ] as [(String?, UInt64?, String, UInt64)])
    func connectionBaselineAdoptsTheGatewayEpochWithoutRewindingDeliveredFrames(
        epoch: String?, delivered: UInt64?, expectedEpoch: String, expectedSequence: UInt64
    ) {
        var cursor = NotificationCursor()
        if let epoch { cursor.adopt(epoch: epoch) }
        if let delivered { cursor.advance(to: delivered) }

        cursor.adoptConnection(epoch: "gateway", deliveredThrough: 40)

        #expect(cursor.epoch == expectedEpoch)
        #expect(cursor.sequence == expectedSequence)
    }

    @Test(arguments: [
        ([], nil), ([7, 12], 12), ([12, 7], 12), ([12, 12], 12),
    ] as [([UInt64], UInt64?)])
    func advancesOnlyForward(deliveries: [UInt64], expected: UInt64?) {
        var cursor = NotificationCursor()
        cursor.adopt(epoch: "gateway")
        for sequence in deliveries { cursor.advance(to: sequence) }

        #expect(cursor.sequence == expected)
    }

    @Test func sequenceWithoutAnEpochIsNotAPosition() {
        var cursor = NotificationCursor()
        cursor.advance(to: 900)

        #expect(cursor.sequence == nil)
        #expect(cursor.replayAfter(pendingReplayFloor: nil) == nil)
        let adopted = cursor.adopt(epoch: "restarted")
        #expect(!adopted)
        #expect(cursor.sequence == nil)
    }

    @Test(arguments: [
        (nil, nil, nil), (12, nil, 12), (12, 8, 7), (5, 8, 5), (nil, 8, 7), (nil, 0, 0),
    ] as [(UInt64?, UInt64?, UInt64?)])
    func replayStartsBeforeTheDroppedFloorAndNeverSkipsUndeliveredFrames(
        delivered: UInt64?, floor: UInt64?, expected: UInt64?
    ) {
        var cursor = NotificationCursor()
        cursor.adopt(epoch: "gateway")
        if let delivered { cursor.advance(to: delivered) }

        #expect(cursor.replayAfter(pendingReplayFloor: floor) == expected)
    }
}
