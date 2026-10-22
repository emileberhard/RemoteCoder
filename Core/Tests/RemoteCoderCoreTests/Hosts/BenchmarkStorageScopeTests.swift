import Foundation
import Testing
@testable import RemoteCoderCore

struct BenchmarkStorageScopeTests {
    @Test func benchmarkNetworkingHasNoContentPersistence() async throws {
        let bench = AppStorageScope.benchmark()
        #expect(bench.isBenchmark)
        #expect(!AppStorageScope.current.isBenchmark)
        let configuration = bench.networkConfiguration(.default)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        let production = URLSessionConfiguration.default
        #expect(AppStorageScope.current.networkConfiguration(production) === production)
        try await bench.discardBenchmark()
    }

    @Test func runsHaveIndependentDefaultsAndFileRoots() async throws {
        let original = AppStorageScope.benchmark()
        let bench = AppStorageScope.benchmark()
        let key = "workspace.open-conversation.v1"
        let saved = ["host": "original-host", "thread": "original-thread", "account": "original-account"]
        original.defaults.set(saved, forKey: key)
        original.defaults.set(1.3, forKey: "appearance.interfaceZoomScale")
        #expect(bench.defaults.object(forKey: key) == nil)
        #expect(bench.defaults.object(forKey: "appearance.interfaceZoomScale") == nil)
        bench.defaults.set(["host": "fixture-host", "thread": "fixture-thread"], forKey: key)
        bench.defaults.set(1.1, forKey: "appearance.interfaceZoomScale")
        #expect(original.defaults.dictionary(forKey: key) as? [String: String] == saved)
        #expect(original.defaults.double(forKey: "appearance.interfaceZoomScale") == 1.3)
        #expect(bench.defaults.dictionary(forKey: key)?["thread"] as? String == "fixture-thread")
        #expect(bench.hostStorage.root != original.hostStorage.root)
        #expect(bench.hostStorage.root != HostStorage.live.root)
        #expect(bench.caches != original.caches)
        try FileManager.default.createDirectory(at: bench.hostStorage.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bench.caches, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: bench.hostStorage.root.appending(path: "checkpoint"))
        try Data("fixture".utf8).write(to: bench.caches.appending(path: "history"))
        try await bench.discardBenchmark()
        #expect(!FileManager.default.fileExists(atPath: bench.applicationSupport.path))
        #expect(!FileManager.default.fileExists(atPath: bench.caches.path))
        #expect(bench.defaults.object(forKey: key) == nil)
        #expect(original.defaults.dictionary(forKey: key) as? [String: String] == saved)
        try await original.discardBenchmark()
    }
}
