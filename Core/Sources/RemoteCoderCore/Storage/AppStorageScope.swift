import Foundation

struct AppStorageScope: Sendable {
    private enum Domain: Sendable { case production, benchmark(UUID) }
    private let domain: Domain

    static var isOfflineReplay: Bool {
        #if RC_PERF_HARNESS
        ProcessInfo.processInfo.arguments.contains("-rcPerfOffline")
        #else
        false
        #endif
    }

    static let current: AppStorageScope = {
        #if RC_PERF_HARNESS
        if isOfflineReplay { return benchmark() }
        #endif
        #if os(macOS) && RC_PERF_HARNESS
        if ProcessInfo.processInfo.arguments.contains("-rcPerfBench") { return benchmark() }
        #endif
        return AppStorageScope(domain: .production)
    }()

    static func benchmark() -> AppStorageScope { AppStorageScope(domain: .benchmark(UUID())) }

    var isBenchmark: Bool {
        if case .benchmark = domain { true } else { false }
    }

    var defaults: UserDefaults {
        switch domain {
        case .production: return UserDefaults.standard
        case .benchmark(let id):
            guard let defaults = UserDefaults(suiteName: "RemoteCoder.mac-bench.\(id.uuidString)") else {
                preconditionFailure("Benchmark defaults domain is unavailable")
            }
            return defaults
        }
    }

    var applicationSupport: URL {
        benchmarkRoot?.appending(path: "ApplicationSupport", directoryHint: .isDirectory) ?? .applicationSupportDirectory
    }

    var caches: URL {
        benchmarkRoot?.appending(path: "Caches", directoryHint: .isDirectory) ?? .cachesDirectory
    }

    var hostStorage: HostStorage { HostStorage(root: applicationSupport.appending(path: "RemoteCoder")) }

    func networkConfiguration(_ production: URLSessionConfiguration) -> URLSessionConfiguration {
        guard case .benchmark = domain else { return production }
        let configuration = URLSessionConfiguration.ephemeral
        #if RC_PERF_HARNESS
        if Self.isOfflineReplay {
            configuration.protocolClasses = [PerformanceReplayHTTP.self]
        }
        #endif
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static let networkSession: URLSession = {
        guard case .benchmark = current.domain else { return .shared }
        return URLSession(configuration: current.networkConfiguration(.default))
    }()

    private var benchmarkRoot: URL? {
        guard case .benchmark(let id) = domain else { return nil }
        return URL.temporaryDirectory.appending(path: "RemoteCoder-mac-bench/\(id.uuidString)", directoryHint: .isDirectory)
    }

    @concurrent func discardBenchmark() async throws {
        guard case .benchmark(let id) = domain, let benchmarkRoot else { return }
        if benchmarkRoot == Self.current.benchmarkRoot { Self.networkSession.invalidateAndCancel() }
        defaults.removePersistentDomain(forName: "RemoteCoder.mac-bench.\(id.uuidString)")
        do { try FileManager.default.removeItem(at: benchmarkRoot) }
        catch CocoaError.fileNoSuchFile {}
    }
}
