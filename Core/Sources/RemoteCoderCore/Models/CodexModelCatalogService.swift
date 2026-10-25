import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CodexModelCatalogService {
    typealias PageLoader = @Sendable (_ cursor: String?) async throws -> CodexAppServerV2.ModelListResponse

    private(set) var catalog: CodexModelCatalog?
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    private(set) var hasFetched = false

    @ObservationIgnored private let storage: CodexModelCatalogStorage
    @ObservationIgnored private let loadPage: PageLoader
    @ObservationIgnored private var hasRestoredCache = false
    @ObservationIgnored private let logger = AppLogger(category: "CodexModelCatalog")

    private static let maxPages = 20

    enum RefreshError: LocalizedError {
        case empty
        case unfinishedPagination

        var errorDescription: String? {
            switch self {
            case .empty: "The host reported no Codex models."
            case .unfinishedPagination: "The host's model list did not finish paging."
            }
        }
    }

    init(directory: URL, loadPage: @escaping PageLoader) {
        storage = CodexModelCatalogStorage(fileURL: directory.appending(path: "codex-models.json"))
        self.loadPage = loadPage
    }

    func restoreCachedCatalog() async {
        guard !hasRestoredCache, !Task.isCancelled else { return }
        let cached = await storage.load()
        guard !hasRestoredCache, !Task.isCancelled else { return }
        hasRestoredCache = true
        if !hasFetched { catalog = cached }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            await restoreCachedCatalog()
            try Task.checkCancellation()
            let models = try await fetchAllPages()
            try Task.checkCancellation()
            guard !models.isEmpty else { throw RefreshError.empty }
            let snapshot = CodexModelCatalogSnapshot(models: models, fetchedAt: .now)
            let prepared = await storage.prepare(snapshot)
            try Task.checkCancellation()
            catalog = prepared
            refreshError = nil
            hasFetched = true
            await storage.save(snapshot)
        } catch is CancellationError {
            return
        } catch {
            refreshError = error.localizedDescription
            logger.error("Codex model list refresh failed: \(error.localizedDescription)")
        }
    }

    private func fetchAllPages() async throws -> [CodexAppServerV2.Model] {
        var models: [CodexAppServerV2.Model] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let page = try await loadPage(cursor)
            models += page.data
            guard let next = page.nextCursor else { return models }
            guard next != cursor else { throw RefreshError.unfinishedPagination }
            cursor = next
        }
        throw RefreshError.unfinishedPagination
    }

}

private struct CodexModelCatalogSnapshot: Codable, Sendable {
    let models: [CodexAppServerV2.Model]
    let fetchedAt: Date
}

private actor CodexModelCatalogStorage {
    private let fileURL: URL
    private let logger = AppLogger(category: "CodexModelCatalog")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func prepare(_ snapshot: CodexModelCatalogSnapshot) -> CodexModelCatalog {
        CodexModelCatalog(models: snapshot.models, fetchedAt: snapshot.fetchedAt)
    }

    func save(_ snapshot: CodexModelCatalogSnapshot) {
        guard !Task.isCancelled else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Could not persist the Codex model list: \(error.localizedDescription)")
        }
    }

    func load() -> CodexModelCatalog? {
        guard !Task.isCancelled else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(CodexModelCatalogSnapshot.self, from: Data(contentsOf: fileURL))
            return prepare(snapshot)
        } catch {
            logger.error("Ignoring an unreadable Codex model list: \(error.localizedDescription)")
            return nil
        }
    }
}
