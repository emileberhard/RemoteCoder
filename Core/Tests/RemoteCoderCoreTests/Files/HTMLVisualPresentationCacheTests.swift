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
        let metadata = try await restored.load().entries
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
        let metadata = try await cache.load().entries
        #expect(metadata[key(0)] == .init(height: 2_400, hasImage: false))
        #expect(metadata[key(1)] == .init(height: 300, hasImage: false))
        #expect(try await cache.image(for: key(0)) == nil)
        try await cache.retire()
    }

    @Test func boundsEncodedBytesWhileRetainingMoreThan128ImagesAndTheirHeights() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        let large = Data(repeating: 42, count: 13 << 20)
        _ = try await cache.store(key(0), height: 480, image: large)
        let metadata = try await cache.store(key(1), height: 481, image: large).entries
        #expect(metadata[key(0)] == .init(height: 480, hasImage: false))
        #expect(try await cache.image(for: key(0)) == nil)
        #expect(try await cache.image(for: key(1))?.count == 13 << 20)
        for index in 2...129 {
            _ = try await cache.store(key(index), height: Double(index), image: Data([UInt8(index)]))
        }
        try await cache.retire()
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let loaded = try await restored.load().entries
        #expect(loaded.count == 130)
        #expect(loaded.values.filter(\.hasImage).count == 129)
        #expect(loaded[key(1)]?.height == 481)
        #expect(try await restored.image(for: key(1)) == large)
        #expect(try await restored.image(for: key(129)) == Data([129]))
        try await restored.retire()
    }

    @Test func boundsHeightRecordsOldestFirstAndPreservesLatestUpdate() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        for index in 0..<512 {
            _ = try await cache.store(key(index), height: Double(index), image: nil)
        }
        _ = try await cache.store(key(0), height: 900, image: nil)
        _ = try await cache.store(key(512), height: 512, image: nil)
        try await cache.retire()
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let loaded = try await restored.load().entries
        #expect(loaded.count == 512)
        #expect(loaded[key(1)] == nil)
        #expect(loaded[key(0)]?.height == 900)
        #expect(loaded[key(512)]?.height == 512)
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
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "index-v3.plist").path))
        #expect(clock.waitingCount == 1)
        try await cache.retire()
        #expect(clock.waitingCount == 0)
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let metadata = try await restored.load().entries
        #expect(metadata[key(0)] == .init(height: 120, hasImage: true))
        #expect(try await restored.image(for: key(0)) == Data([1]))
        await #expect(throws: HTMLVisualPresentationError.retired) { try await cache.load().entries }
        try await restored.retire()
    }

    @Test func storesEachImageInItsOwnFileAndRewritesOnlyChangedImagesAndTheIndex() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        for index in 0..<3 {
            _ = try await cache.store(key(index), height: 300, image: Data(repeating: UInt8(index), count: 50_000))
        }
        try await cache.flush()
        let images = directory.appending(path: "images")
        let written = try imageFiles(images)
        #expect(written.count == 3)
        let index = try Data(contentsOf: directory.appending(path: "index-v3.plist"))
        #expect(index.count < 4_096)
        _ = try await cache.store(key(0), height: 300, image: nil)
        try await cache.flush()
        #expect(try imageFiles(images) == written)
        #expect(try Data(contentsOf: directory.appending(path: "index-v3.plist")) == index)
        try await cache.retire()
    }

    @Test func dropsImagesWhoseFilesAreMissingOrTruncatedAndRemovesOrphans() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appending(path: "images")
        let first = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        _ = try await first.store(key(0), height: 300, image: Data(repeating: 1, count: 2_000))
        try await first.retire()
        let truncated = try #require(try imageFiles(images).first)
        try Data(repeating: 1, count: 1_000).write(to: images.appending(path: truncated))

        let second = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await second.load().entries[key(0)] == .init(height: 300, hasImage: false))
        #expect(try await second.image(for: key(0)) == nil)
        _ = try await second.store(key(1), height: 400, image: Data(repeating: 2, count: 3_000))
        try await second.retire()
        #expect(try imageFiles(images).count == 1)
        try Data([9]).write(to: images.appending(path: "orphan.pdf"))

        let third = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        let loaded = try await third.load().entries
        #expect(loaded[key(0)] == .init(height: 300, hasImage: false))
        #expect(loaded[key(1)] == .init(height: 400, hasImage: true))
        #expect(try await third.image(for: key(1)) == Data(repeating: 2, count: 3_000))
        #expect(!(try imageFiles(images).contains("orphan.pdf")))
        for file in try imageFiles(images) { try FileManager.default.removeItem(at: images.appending(path: file)) }
        try await third.retire()

        let fourth = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await fourth.load().entries[key(1)] == .init(height: 400, hasImage: false))
        try await fourth.retire()
    }

    @Test func versionTwoCacheMigratesItsImagesIntoSeparateFiles() async throws {
        struct Record: Codable {
            let key: HTMLVisualLayoutKey
            let height: Double
            let heightOrder: UInt64
            let image: Data?
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
        try encoder.encode(Envelope(version: 2, records: [
            Record(key: key(0), height: 500, heightOrder: 1, image: Data(repeating: 7, count: 40_000), imageOrder: 1),
            Record(key: key(1), height: 600, heightOrder: 2, image: nil, imageOrder: nil),
        ])).write(to: directory.appending(path: "presentations.plist"))
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await cache.load().entries[key(0)] == .init(height: 500, hasImage: true))
        try await cache.retire()
        #expect(try imageFiles(directory.appending(path: "images")).count == 1)
        #expect(try Data(contentsOf: directory.appending(path: "index-v3.plist")).count < 4_096)
        let restored = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        #expect(try await restored.load().entries == [key(0): .init(height: 500, hasImage: true), key(1): .init(height: 600, hasImage: false)])
        #expect(try await restored.image(for: key(0)) == Data(repeating: 7, count: 40_000))
        try await restored.retire()
    }

    @Test func bothThemesSurvivePreparationAndRelaunchWithoutMissingSnapshots() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        for dark in [false, true] {
            for index in 0..<168 {
                _ = try await cache.store(key(index, dark: dark), height: dark ? 420 : 400,
                    image: Data(repeating: UInt8(index), count: 57_000), protecting: [])
            }
        }
        try await cache.retire()
        let restored = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        for dark in [false, true, false] {
            let entries = try await restored.load().entries
            for index in 0..<168 {
                let key = key(index, dark: dark)
                #expect(entries[key] == .init(height: dark ? 420 : 400, hasImage: true))
                #expect(try await restored.image(for: key) == Data(repeating: UInt8(index), count: 57_000))
            }
        }
        try await restored.retire()
    }

    @Test func laterPreparationEvictsLeastRecentlyUsedImagesAndPreservesPresentedKeys() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        let image = Data(repeating: 1, count: 8 << 20)
        for index in 0..<3 {
            _ = try await cache.store(key(index), height: 100, image: image, protecting: [])
        }
        #expect(try await cache.image(for: key(1)) == image)
        let entries = try await cache.store(key(3), height: 200, image: image, protecting: [key(0)]).entries
        #expect(entries[key(0)]?.hasImage == true)
        #expect(entries[key(1)]?.hasImage == true)
        #expect(entries[key(2)]?.hasImage == false)
        #expect(entries[key(3)]?.hasImage == true)
        await #expect(throws: HTMLVisualPresentationError.capacity) {
            try await cache.store(key(4), height: 300, image: image, protecting: [key(0), key(1), key(3)])
        }
        #expect(try await cache.load().entries == entries)
        try await cache.retire()
        #expect(try imageFiles(directory.appending(path: "images")).count == 1)
    }

    @Test func sameSizeCorruptionNeverServesTheWrongImage() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        _ = try await cache.store(key(0), height: 300, image: Data([1, 2, 3]))
        try await cache.retire()
        let images = directory.appending(path: "images")
        let file = try #require(try imageFiles(images).first)
        try Data([4, 5, 6]).write(to: images.appending(path: file))
        let restored = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await restored.image(for: key(0)) == nil)
        #expect(try await restored.load().entries[key(0)] == .init(height: 300, hasImage: false))
        try await restored.retire()
        #expect(try imageFiles(images).isEmpty)
    }

    @Test func oldReaderCanLoadAndStoreAfterMigrationAndTheNextUpgradeReclaimsItsCache() async throws {
        struct Record3768: Codable {
            let key: HTMLVisualLayoutKey
            let height: Double
            let heightOrder: UInt64
            let image: Data?
            let imageOrder: UInt64?
        }
        struct Envelope3768: Codable {
            let version: Int
            let records: [Record3768]
        }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appending(path: "presentations.plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let old = Envelope3768(version: 2, records: [
            Record3768(key: key(0), height: 100, heightOrder: 1, image: Data([7]), imageOrder: 1),
        ])
        try encoder.encode(old).write(to: legacy, options: .atomic)
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await cache.load().entries[key(0)] == .init(height: 100, hasImage: true))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        _ = try await cache.store(key(1), height: 200, image: Data([8]))
        try await cache.retire()
        let current = try Data(contentsOf: directory.appending(path: "index-v3.plist"))

        let loadedByOld = FileManager.default.fileExists(atPath: legacy.path)
            ? try PropertyListDecoder().decode(Envelope3768.self, from: Data(contentsOf: legacy))
            : Envelope3768(version: 2, records: [])
        #expect(loadedByOld.version == 2 && loadedByOld.records.isEmpty)
        let writtenByOld = Envelope3768(version: 2, records: [
            Record3768(key: key(2), height: 300, heightOrder: 1, image: Data([9]), imageOrder: 1),
        ])
        try encoder.encode(writtenByOld).write(to: legacy, options: .atomic)
        let coldOld = try PropertyListDecoder().decode(Envelope3768.self, from: Data(contentsOf: legacy))
        #expect((1...2).contains(coldOld.version) && coldOld.records.count <= 256)
        #expect(coldOld.records.first?.image == Data([9]))

        let restored = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await restored.load().entries == [key(0): .init(height: 100, hasImage: true), key(1): .init(height: 200, hasImage: true)])
        #expect(try await restored.image(for: key(0)) == Data([7]))
        #expect(try await restored.image(for: key(1)) == Data([8]))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: directory.appending(path: "index-v3.plist")) == current)
        try await restored.retire()
        #expect(try imageFiles(directory.appending(path: "images")).count == 2)
    }

    @Test func failedIndexCommitsKeepPreviousImagesAndReclaimSupersededFiles() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        _ = try await cache.store(key(0), height: 100, image: Data([0]))
        try await cache.flush()
        let url = directory.appending(path: "index-v3.plist")
        let committed = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for value in 1...8 {
            _ = try await cache.store(key(0), height: Double(value), image: Data([UInt8(value)]))
            await #expect(throws: (any Error).self) { try await cache.flush() }
            #expect(try imageFiles(directory.appending(path: "images")).count == 2)
        }
        try FileManager.default.removeItem(at: url)
        try committed.write(to: url)
        let previous = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        #expect(try await previous.image(for: key(0)) == Data([0]))
        try await previous.retire()
        _ = try await cache.store(key(0), height: 8, image: Data([8]))
        try await cache.retire()
        #expect(try imageFiles(directory.appending(path: "images")).count == 1)
    }

    @Test func outOfOrderStoreCompletionsCannotRestoreEvictedCoverage() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HTMLVisualPresentationCache(directory: directory, clock: FrozenVisualClock())
        let image = Data(repeating: 1, count: 13 << 20)
        let earlier = try await cache.store(key(0), height: 100, image: image)
        let later = try await cache.store(key(1), height: 200, image: image)
        #expect(later.generation > earlier.generation)
        #expect(later.entries[key(0)]?.hasImage == false)
        var coverage = HTMLVisualPresentationCoverage()
        coverage.apply(later)
        coverage.apply(earlier)
        #expect(!coverage.contains(key(0)))
        #expect(coverage.contains(key(1)))
        let heightSave = try await cache.store(key(1), height: 201, image: nil)
        coverage.apply(heightSave)
        coverage.apply(later)
        #expect(!coverage.contains(key(0)))
        #expect(coverage.contains(key(1)))
        try await cache.retire()
    }

    private func imageFiles(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
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
