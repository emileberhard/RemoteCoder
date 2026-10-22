import Foundation

@MainActor
enum BoundedFanOut {
    /// Shared cursor for the bounded fan-out. Main-actor state, so the workers
    /// hand it back and forth at their awaits without any locking.
    @MainActor
    private final class Queue<Item> {
        private var pending: [Item]
        private let isStale: @MainActor (Item) -> Bool

        init(_ items: [Item], isStale: @escaping @MainActor (Item) -> Bool) {
            pending = items
            self.isStale = isStale
        }

        func next() -> Item? {
            while !pending.isEmpty {
                let item = pending.removeFirst()
                // An item that went stale while the queue drained has no work left.
                if !isStale(item) { return item }
            }
            return nil
        }
    }

    /// Runs `body` for every item, at most `limit` at a time, in the given order.
    ///
    /// The workers slide: each one takes the next item as soon as it finishes, so
    /// one slow item delays only itself, never the items behind it in a fixed
    /// batch. They are unstructured (a `withTaskGroup` of `@MainActor` child
    /// tasks trips the region-based isolation checker), so cancellation is
    /// forwarded explicitly.
    static func run<Item>(
        _ items: [Item],
        limit: Int,
        skipping isStale: @escaping @MainActor (Item) -> Bool,
        _ body: @escaping @MainActor (Item) async -> Void
    ) async {
        precondition(limit > 0, "a fan-out needs at least one worker")
        guard !items.isEmpty else { return }
        let queue = Queue(items, isStale: isStale)
        let workers = (0..<min(limit, items.count)).map { _ in
            Task { @MainActor in
                while let item = queue.next() {
                    guard !Task.isCancelled else { return }
                    await body(item)
                }
            }
        }
        await withTaskCancellationHandler {
            for worker in workers { await worker.value }
        } onCancel: {
            for worker in workers { worker.cancel() }
        }
    }
}
