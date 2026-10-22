import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct OwnedTasksTests {
    @Test func quiescingJoinsCancelledPredecessorsAndReopensOnlyAfterTheirCompletion() async throws {
        let tasks = OwnedTasks<String>()
        let entered = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var order: [String] = []
        tasks.start("read") {
            await withCheckedContinuation {
                release = $0
                entered.continuation.yield()
            }
            order.append("admitted mutation")
        }
        for await _ in entered.stream { break }
        await tasks.start("read") { order.append("replacement") }.value
        tasks.quiesce()
        await tasks.start("closed") { order.append("rejected mutation") }.value
        let joining = AsyncStream<Void>.makeStream()
        let flush = Task {
            joining.continuation.yield()
            await tasks.drain()
            order.append("flush")
        }
        for await _ in joining.stream { break }
        #expect(!order.contains("flush"))
        try #require(release).resume()
        await flush.value
        #expect(order == ["replacement", "admitted mutation", "flush"])
        tasks.resume()
        await tasks.start("reopened") { order.append("normal mutation") }.value
        #expect(order.last == "normal mutation")
        entered.continuation.finish()
        joining.continuation.finish()
    }
}
