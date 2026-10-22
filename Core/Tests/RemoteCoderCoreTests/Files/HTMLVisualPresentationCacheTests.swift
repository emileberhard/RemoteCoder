import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

struct HTMLVisualPresentationCacheTests {
    @Test func restoresHeightAndEncodedImageUsingTheFullLayoutKey() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let key = key(0)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        _ = try await cache.store(key, height: 460, image: png)
        try await cache.retire()
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let metadata = try await restored.load()
        #expect(metadata[key] == .init(height: 460, hasImage: true))
        #expect(try await restored.image(for: key) == png)
        #expect(metadata[self.key(0, width: 640)] == nil)
        #expect(metadata[self.key(0, dark: true)] == nil)
        try await restored.retire()
    }

    @Test func versionOneCacheKeepsHeightsAndDropsItsPartialPNGSnapshots() async throws {
        struct Record: Codable {
            let key: HTMLVisualLayoutKey
            let height: Double
            let heightOrder: UInt64
            let image: Data?
            let imageHeight: Double?
            let imageOrder: UInt64?
        }
        struct Envelope: Codable {
            let version: Int
            let records: [Record]
        }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(Envelope(version: 1, records: [
            Record(key: key(0), height: 2_400, heightOrder: 1, image: Data([1, 2, 3]), imageHeight: 800, imageOrder: 1),
            Record(key: key(1), height: 300, heightOrder: 2, image: nil, imageHeight: nil, imageOrder: nil),
        ])).write(to: directory.appending(path: "presentations.plist"))
        let cache = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let metadata = try await cache.load()
        #expect(metadata[key(0)] == .init(height: 2_400, hasImage: false))
        #expect(metadata[key(1)] == .init(height: 300, hasImage: false))
        #expect(try await cache.image(for: key(0)) == nil)
        try await cache.retire()
    }

    @Test func boundsEncodedBytesAndImageCountWhileRetainingHeights() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        let large = Data(repeating: 42, count: 13 << 20)
        _ = try await cache.store(key(0), height: 480, image: large)
        let metadata = try await cache.store(key(1), height: 481, image: large)
        #expect(metadata[key(0)] == .init(height: 480, hasImage: false))
        #expect(try await cache.image(for: key(0)) == nil)
        #expect(try await cache.image(for: key(1))?.count == 13 << 20)
        for index in 2...129 {
            _ = try await cache.store(key(index), height: Double(index), image: Data([UInt8(index)]))
        }
        try await cache.retire()
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let loaded = try await restored.load()
        #expect(loaded.count == 130)
        #expect(loaded.values.filter(\.hasImage).count == 128)
        #expect(loaded[key(1)]?.height == 481)
        #expect(try await restored.image(for: key(1)) == nil)
        #expect(try await restored.image(for: key(129)) == Data([129]))
        try await restored.retire()
    }

    @Test func boundsHeightRecordsOldestFirstAndPreservesLatestUpdate() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        for index in 0..<256 {
            _ = try await cache.store(key(index), height: Double(index), image: nil)
        }
        _ = try await cache.store(key(0), height: 900, image: nil)
        _ = try await cache.store(key(256), height: 256, image: nil)
        try await cache.retire()
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let loaded = try await restored.load()
        #expect(loaded.count == 256)
        #expect(loaded[key(1)] == nil)
        #expect(loaded[key(0)]?.height == 900)
        #expect(loaded[key(256)]?.height == 256)
        try await restored.retire()
    }

    @Test func coalescesPendingMeasurementsUntilFlushAndRetiresItsClockWork() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FrozenVisualClock()
        let cache = HTMLVisualPresentationCache(directory: directory, clock: clock)
        _ = try await cache.store(key(0), height: 100, image: Data([1]))
        await clock.waitUntilSleeping()
        for height in 101...120 {
            _ = try await cache.store(key(0), height: Double(height), image: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "presentations.plist").path))
        #expect(clock.waitingCount == 1)
        try await cache.retire()
        #expect(clock.waitingCount == 0)
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let metadata = try await restored.load()
        #expect(metadata[key(0)] == .init(height: 120, hasImage: true))
        #expect(try await restored.image(for: key(0)) == Data([1]))
        await #expect(throws: HTMLVisualPresentationError.retired) { try await cache.load() }
        try await restored.retire()
    }

    private func key(_ index: Int, width: Int = 360, dark: Bool = false) -> HTMLVisualLayoutKey {
        HTMLVisualLayoutKey(digest: String(format: "%064x", index), width: width,
            theme: HTMLVisualTheme(fontSize: 17, text: "#111111", secondaryText: "#444444",
                background: "#ffffff", surface: "#eeeeee", accent: "#3377ff", isDark: dark))
    }
}

private final class FrozenVisualClock: Clock {
    private struct State {
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var observers: [CheckedContinuation<Void, Never>] = []
    }

    let now = ContinuousClock().now
    let minimumResolution: Duration = .nanoseconds(1)
    private let state = Mutex(State())

    var waitingCount: Int { state.withLock { $0.waiters.count } }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let observers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return []
                    }
                    state.waiters[id] = continuation
                    let observers = state.observers
                    state.observers.removeAll()
                    return observers
                }
                for observer in observers { observer.resume() }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleeping() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if !state.waiters.isEmpty { return true }
                state.observers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
