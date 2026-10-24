import Foundation
import Observation
import OSLog

enum HostHome: Equatable, Sendable {
    case unresolved
    case resolved(String)
    case failed(String)
}

/// Keeps one physical host's directory knowledge: the resolved `$HOME` and the
/// last one it reported, its warm child listing and the favorited paths. One instance per host, owned by
/// `HostServices`, so every consumer reads the same resolution instead of
/// racing its own.
@MainActor
@Observable
final class HostDirectories {
    private(set) var home: HostHome = .unresolved
    private(set) var lastKnownHomePath: String?
    private(set) var information: GatewayClient.HostInfoResponse?
    private(set) var homeChildren: DirectoryListing?
    private(set) var favorites: [String]

    let hostID: UUID
    @ObservationIgnored private let gateway: any HostDirectoryRemote
    @ObservationIgnored private let hostLabel: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let favoritesKey: String
    @ObservationIgnored private let legacyFavoritesKey: String
    @ObservationIgnored private var favoritesReplica = DirectoryFavoritesReplica()
    @ObservationIgnored private var favoritesSync: Task<Void, Never>?
    @ObservationIgnored private var favoritesReadRequested = false
    @ObservationIgnored private let logger = Logger(subsystem: "RemoteCoder", category: "HostDirectories")
    @ObservationIgnored private var refreshLoopTask: Task<Void, Never>?
    @ObservationIgnored private var activeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var informationGeneration = UUID()
    @ObservationIgnored private var homeResolutionTask: Task<GatewayClient.HostInfoResponse, Error>?
    @ObservationIgnored private var visibleOwners: Set<UUID> = []
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var isRetired = false

    init(gateway: any HostDirectoryRemote, hostID: UUID, hostLabel: String, defaults: UserDefaults = AppStorageScope.current.defaults) {
        self.hostID = hostID
        self.gateway = gateway
        self.hostLabel = hostLabel
        self.defaults = defaults
        favoritesKey = "directoryFavorites.\(hostID.uuidString)"
        legacyFavoritesKey = "directoryPicker.favoritePaths.\(hostID.uuidString)"
        favorites = []
        lastKnownHomePath = HostPreferences.remoteHomePath(hostID: hostID, defaults: defaults)
        loadFavorites()
    }

    func toggleFavorite(_ path: String) {
        recordFavorite(favorites.contains(path) ? .remove(path) : .add(path))
    }

    func removeFavorite(_ path: String) {
        recordFavorite(.remove(path))
    }

    @discardableResult
    func syncFavorites() -> Task<Void, Never>? {
        guard !isRetired else { return nil }
        favoritesReadRequested = true
        return startFavoritesSync()
    }

    func receiveFavorites(_ received: DirectoryFavorites) {
        updateFavorites { $0.receive(received) }
    }

    private func recordFavorite(_ change: DirectoryFavoriteChange) {
        guard !isRetired else { return }
        var admitted = false
        updateFavorites { admitted = $0.record(change) }
        guard admitted else {
            logger.error("Favorite change refused host=\(self.hostLabel, privacy: .public): invalid path or \(DirectoryFavoritesReplica.changeLimit, privacy: .public) changes already await the host")
            return
        }
        startFavoritesSync()
    }

    @discardableResult
    private func startFavoritesSync() -> Task<Void, Never> {
        if let favoritesSync { return favoritesSync }
        let task = Task { [weak self] in
            guard let self else { return }
            await runFavoritesSync()
        }
        favoritesSync = task
        return task
    }

    private func runFavoritesSync() async {
        defer { favoritesSync = nil }
        while !isRetired {
            if favoritesReadRequested {
                favoritesReadRequested = false
                guard await readFavorites() else { return }
            }
            let batch = Array(favoritesReplica.pending.prefix(DirectoryFavoritesReplica.changeLimit))
            guard !batch.isEmpty, await sendFavorites(batch) else { return }
        }
    }

    private func readFavorites() async -> Bool {
        let acknowledgedBeforeRead = favoritesReplica.acknowledged
        do {
            let read = try await gateway.readDirectoryFavorites()
            guard !isRetired else { return false }
            updateFavorites { replica in
                if replica.acknowledged == acknowledgedBeforeRead { replica.replace(with: read) } else { replica.receive(read) }
            }
            return true
        } catch {
            favoritesReadRequested = true
            logger.notice("Favorites read failed host=\(self.hostLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sendFavorites(_ batch: [DirectoryFavoriteChange]) async -> Bool {
        do {
            let current = try await gateway.updateDirectoryFavorites(batch)
            guard !isRetired else { return false }
            updateFavorites { $0.acknowledge(batch.count, current: current) }
            return true
        } catch GatewayClient.ClientError.serverError(let message, let code?) where code == Self.invalidParamsCode {
            logger.error("Host refused favorite changes host=\(self.hostLabel, privacy: .public): \(message, privacy: .public)")
            updateFavorites { $0.reject(batch.count) }
            favoritesReadRequested = true
            return true
        } catch {
            logger.notice("Favorite changes kept for the next connection host=\(self.hostLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let invalidParamsCode = -32602

    private func loadFavorites() {
        if let data = defaults.data(forKey: favoritesKey) {
            do {
                favoritesReplica = try JSONDecoder().decode(DirectoryFavoritesReplica.self, from: data)
            } catch {
                logger.error("Unreadable favorites cache host=\(self.hostLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else if let legacy = defaults.stringArray(forKey: legacyFavoritesKey) {
            favoritesReplica = DirectoryFavoritesReplica(legacyPaths: legacy)
            persistFavorites()
        }
        favorites = favoritesReplica.paths
    }

    private func updateFavorites(_ change: (inout DirectoryFavoritesReplica) -> Void) {
        let before = favoritesReplica
        change(&favoritesReplica)
        guard favoritesReplica != before else { return }
        let paths = favoritesReplica.paths
        if favorites != paths { favorites = paths }
        persistFavorites()
    }

    private func persistFavorites() {
        do {
            defaults.set(try JSONEncoder().encode(favoritesReplica), forKey: favoritesKey)
        } catch {
            logger.error("Favorites cache write failed host=\(self.hostLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func setVisible(_ visible: Bool, owner: UUID) {
        if visible { visibleOwners.insert(owner) } else { visibleOwners.remove(owner) }
    }

    func startIfNeeded() {
        guard isRetired == false, refreshLoopTask == nil else { return }
        refreshLoopTask = Task { await refreshLoop() }
    }

    /// Stops the periodic refresh while the app is backgrounded; the cache and
    /// favorites survive so returning to foreground repaints immediately.
    func suspendRefreshLoop() {
        isSuspended = true
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
    }

    func triggerForegroundRefresh() async {
        guard isRetired == false else { return }
        isSuspended = false
        startIfNeeded()
        await refresh(reason: "foreground")
    }

    /// Releases everything owned by a retired host so a removed or
    /// reconfigured host cannot keep polling in the background.
    func retire() async {
        isRetired = true
        isSuspended = true
        let loop = refreshLoopTask
        let refresh = activeRefreshTask
        let resolution = homeResolutionTask
        let favoritesSync = favoritesSync
        loop?.cancel()
        refresh?.cancel()
        resolution?.cancel()
        favoritesSync?.cancel()
        refreshLoopTask = nil
        activeRefreshTask = nil
        homeResolutionTask = nil
        await loop?.value
        await refresh?.value
        _ = await resolution?.result
        await favoritesSync?.value
    }

    func connectionChanged() {
        informationGeneration = UUID()
        information = nil
        homeResolutionTask?.cancel()
        homeResolutionTask = nil
    }

    func resolveHomePath() async throws -> String {
        while true {
            let generation = informationGeneration
            do {
                return try await resolveHomePath(in: generation)
            } catch {
                guard generation != informationGeneration else { throw error }
            }
        }
    }

    private func resolveHomePath(in generation: UUID) async throws -> String {
        guard !isRetired else { throw HostDirectoriesError.retired }
        try Task.checkCancellation()
        if information != nil, case .resolved(let path) = home { return path }
        if let homeResolutionTask { return try await homeResolutionTask.value.homeDirectory }

        let gateway = self.gateway
        let task = Task { try await gateway.readHostInfo() }
        homeResolutionTask = task
        do {
            let result = try await task.value
            let resolved = result.homeDirectory
            guard generation == informationGeneration else { throw CancellationError() }
            guard !isRetired else { throw HostDirectoriesError.retired }
            try Task.checkCancellation()
            information = result
            home = .resolved(resolved)
            if lastKnownHomePath != resolved {
                lastKnownHomePath = resolved
                HostPreferences.setRemoteHomePath(resolved, hostID: hostID, defaults: defaults)
            }
            homeResolutionTask = nil
            logger.notice("Resolved remote home for \(self.hostLabel, privacy: .public): \(resolved, privacy: .public)")
            return resolved
        } catch {
            guard generation == informationGeneration else { throw error }
            homeResolutionTask = nil
            if !(error is CancellationError) { home = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// Expands `~` and `~/...` against the resolved home; every other path is
    /// already absolute.
    func expandedPath(_ path: String) async throws -> String {
        if path == "~" { return try await resolveHomePath() }
        if path.hasPrefix("~/") {
            let home = try await resolveHomePath()
            return "\(home)/\(path.dropFirst(2))"
        }
        return path
    }

    func list(_ path: String) async throws -> DirectoryListing {
        let expanded = try await expandedPath(path)
        let response = try await gateway.readDirectory(path: expanded)
        return await Self.parseListing(path: expanded, response: response)
    }

    @concurrent
    private static func parseListing(
        path: String,
        response: CodexAppServerV2.FsReadDirectoryResponse
    ) async -> DirectoryListing {
        DirectoryListing(path: path, response: response)
    }

    private func refreshLoop() async {
        await refresh(reason: "initial")
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60), tolerance: .seconds(6)) }
            catch { return }
            guard isSuspended == false, isRetired == false else { return }
            if !visibleOwners.isEmpty { await refresh(reason: "timer") }
        }
    }

    private func refresh(reason: String) async {
        guard isRetired == false else { return }
        if let activeRefreshTask {
            await activeRefreshTask.value
            return
        }
        let task = Task { await performRefresh(reason: reason) }
        activeRefreshTask = task
        await task.value
        activeRefreshTask = nil
    }

    private func performRefresh(reason: String) async {
        do {
            let listing = try await list("~")
            guard isRetired == false else { return }
            if homeChildren != listing {
                homeChildren = listing
            }
            logger.notice(
                "Prefetched \(listing.childNames.count, privacy: .public) home subdirectories for \(self.hostLabel, privacy: .public) (reason=\(reason, privacy: .public))"
            )
        } catch {
            guard isRetired == false else { return }
            logger.error(
                "Prefetch refresh failed host=\(self.hostLabel, privacy: .public) reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

enum HostDirectoriesError: LocalizedError {
    case retired
    var errorDescription: String? { "This host's directory service has been retired." }
}
