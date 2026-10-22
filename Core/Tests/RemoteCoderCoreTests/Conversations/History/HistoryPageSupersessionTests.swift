import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryPageSupersessionTests {
    private func key(_ threadID: String, _ generation: UInt64, _ request: String = "items") -> HistoryPageKey {
        HistoryPageKey(hostID: "host", provider: "native", threadID: threadID, generation: generation, request: request)
    }

    private func store(_ key: HistoryPageKey, in cache: HistoryPageCache) async throws {
        let startedAt = ContinuousClock.now
        try await cache.store(Data("\(key.threadID)-\(key.generation)-\(key.request)".utf8), for: key, startedAt: startedAt, readStartedAt: startedAt)
    }

    private func plists(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "plist" }
    }

    @Test func aNewerGenerationDiscardsAndThenRejectsOnlyTheSameRequestsOlderPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        for key in [key("live", 1), key("live", 1, "turns"), key("other", 1), key("live", 0, "tail")] {
            try await store(key, in: cache)
        }

        try await store(key("live", 2), in: cache)
        try await store(key("live", 1), in: cache)

        #expect(await cache.value(for: key("live", 1)) == nil)
        #expect(await cache.value(for: key("live", 2)) != nil)
        #expect(await cache.value(for: key("live", 1, "turns")) != nil)
        #expect(await cache.value(for: key("other", 1)) != nil)
        #expect(await cache.value(for: key("live", 0, "tail")) != nil)
        #expect(try plists(in: directory).count == 4)
    }

    @Test func loadingTheDiskIndexKeepsOnlyTheNewestGenerationOfEachRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let merged = root.appendingPathComponent("merged")
        try FileManager.default.createDirectory(at: merged, withIntermediateDirectories: true)
        for generation: UInt64 in [3, 1, 2] {
            let directory = root.appendingPathComponent("\(generation)")
            try await store(key("live", generation), in: HistoryPageCache(directory: directory))
            for url in try plists(in: directory) {
                try FileManager.default.copyItem(at: url, to: merged.appendingPathComponent(url.lastPathComponent))
            }
        }

        let cache = HistoryPageCache(directory: merged)

        #expect(await cache.value(for: key("live", 3)) != nil)
        #expect(await cache.value(for: key("live", 2)) == nil)
        #expect(await cache.value(for: key("live", 1)) == nil)
        #expect(try plists(in: merged).count == 1)
    }
}
