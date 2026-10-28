import Testing
@testable import RemoteCoderCore

@MainActor
struct BoundedFanOutTests {
    private final class Recorder {
        var active = 0
        var peak = 0
        var started: [Int] = []
    }

    @Test func neverRunsMoreThanTheLimitAtOnce() async {
        let recorder = Recorder()
        await BoundedFanOut.run(Array(1...6), limit: 2, deadline: nil, skipping: { _ in false }) { item in
            recorder.started.append(item)
            recorder.active += 1
            recorder.peak = max(recorder.peak, recorder.active)
            for _ in 0..<3 { await Task.yield() }
            recorder.active -= 1
        }
        #expect(recorder.peak == 2)
        #expect(recorder.started.sorted() == Array(1...6))
    }

    @Test func aSingleWorkerKeepsTheGivenOrder() async {
        let recorder = Recorder()
        await BoundedFanOut.run([3, 1, 2], limit: 1, deadline: nil, skipping: { _ in false }) { recorder.started.append($0) }
        #expect(recorder.started == [3, 1, 2])
    }

    @Test func anItemThatGoesStaleWhileQueuedIsSkipped() async {
        let recorder = Recorder()
        let staleBox = StaleBox([4])
        await BoundedFanOut.run([1, 2, 3, 4], limit: 1, deadline: nil, skipping: { staleBox.items.contains($0) }) { item in
            if item == 2 { staleBox.items.insert(3) }
            recorder.started.append(item)
        }
        #expect(recorder.started == [1, 2])
    }

    @Test func cancellingTheCallerStopsTheWorkersBeforeTheNextItem() async {
        let recorder = Recorder()
        let task = Task { @MainActor in
            await BoundedFanOut.run([1, 2, 3], limit: 1, deadline: nil, skipping: { _ in false }) { item in
                recorder.started.append(item)
                while !Task.isCancelled { await Task.yield() }
            }
        }
        while recorder.started.isEmpty { await Task.yield() }
        task.cancel()
        await task.value
        #expect(recorder.started == [1])
    }

    @Test func anExpiredDeadlineStartsNoWork() async {
        let recorder = Recorder()
        await BoundedFanOut.run([1, 2, 3], limit: 3, deadline: .now - .seconds(1), skipping: { _ in false }) {
            recorder.started.append($0)
        }
        #expect(recorder.started.isEmpty)
    }

    private final class StaleBox {
        var items: Set<Int>
        init(_ items: Set<Int>) { self.items = items }
    }
}
