import Foundation
import Testing

@testable import RemoteCoderCore

struct NotificationHubTests {
    private func note(thread: String, sequence: UInt64?) -> CodexGatewayNotification {
        CodexGatewayNotification(method: "item/completed", params: .object(["threadId": .string(thread)]), server: ServerNotification.decode(method: "item/completed", params: .object(["threadId": .string(thread)])), sequence: sequence)
    }

    @Test func aDroppedNotificationEmitsItsThreadAndKeepsTheReplayFloorUntilTaken() async {
        var hub = NotificationHub()
        let stream = AsyncStream<CodexGatewayNotification>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            _ = hub.add(continuation)
        }
        let events = AsyncStream<GatewayConnectionEvent>(bufferingPolicy: .bufferingNewest(4)) { continuation in
            _ = hub.addEventSubscriber(continuation)
        }
        var received = events.makeAsyncIterator()

        let first = hub.publish(note(thread: "thread-1", sequence: 5))
        let second = hub.publish(note(thread: "thread-2", sequence: 6))

        #expect(!first)
        #expect(second)
        withExtendedLifetime(stream) {}
        hub.finishEvents()
        var seen: [GatewayConnectionEvent] = []
        while let event = await received.next() { seen.append(event) }
        #expect(seen == [.historyGap(threads: ["thread-1"], allThreads: false)])
        #expect(hub.takeReplayFloor() == 5)
        #expect(hub.takeReplayFloor() == nil)
    }

    @Test func aDroppedNotificationWithoutAThreadMarksEveryThread() async {
        var hub = NotificationHub()
        let stream = AsyncStream<CodexGatewayNotification>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            _ = hub.add(continuation)
        }
        let events = AsyncStream<GatewayConnectionEvent>(bufferingPolicy: .bufferingNewest(4)) { continuation in
            _ = hub.addEventSubscriber(continuation)
        }
        var received = events.makeAsyncIterator()

        _ = hub.publish(CodexGatewayNotification(method: "daemon/transportError", params: nil, server: ServerNotification.decode(method: "daemon/transportError", params: nil), sequence: nil))
        _ = hub.publish(note(thread: "thread-1", sequence: nil))

        withExtendedLifetime(stream) {}
        hub.finishEvents()
        var seen: [GatewayConnectionEvent] = []
        while let event = await received.next() { seen.append(event) }
        #expect(seen == [.historyGap(threads: [], allThreads: true)])
    }
}
