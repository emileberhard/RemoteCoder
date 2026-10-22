import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct HostDirectoriesFavoritesTests {
    @Test func everyDevicesFormerFavoritesReachTheHostAndTheHostListWins() async throws {
        let suite = "HostDirectoriesFavoritesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostID = UUID()
        defaults.set(["/work/newest", "/work/oldest"], forKey: "directoryPicker.favoritePaths.\(hostID.uuidString)")
        let remote = FavoritesRemote(DirectoryFavorites(revision: 4, paths: ["/work/other-device"]))

        let directories = HostDirectories(gateway: remote, hostID: hostID, hostLabel: "Test", defaults: defaults)
        #expect(directories.favorites == ["/work/newest", "/work/oldest"])
        await directories.syncFavorites()?.value

        #expect(await remote.updates == [[.add("/work/oldest"), .add("/work/newest")]])
        #expect(directories.favorites == ["/work/newest", "/work/oldest", "/work/other-device"])

        let relaunched = HostDirectories(gateway: remote, hostID: hostID, hostLabel: "Test", defaults: defaults)
        #expect(relaunched.favorites == directories.favorites)
        await relaunched.syncFavorites()?.value
        #expect(await remote.updates.count == 1)
    }

    @Test func onlyAnInvalidBatchIsDroppedWhileOtherFailuresKeepTheChange() async throws {
        let suite = "HostDirectoriesFavoritesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = FavoritesRemote(DirectoryFavorites(revision: 1, paths: ["/a"]))
        let directories = HostDirectories(gateway: remote, hostID: UUID(), hostLabel: "Test", defaults: defaults)

        await remote.failUpdates(with: GatewayClient.ClientError.serverError(message: "busy", code: -32001))
        directories.toggleFavorite("/b")
        await directories.syncFavorites()?.value
        #expect(directories.favorites == ["/b", "/a"])

        await remote.failUpdates(with: GatewayClient.ClientError.serverError(message: "invalid", code: -32602))
        await directories.syncFavorites()?.value
        #expect(directories.favorites == ["/a"])

        await remote.failUpdates(with: nil)
        directories.toggleFavorite("/c")
        await directories.syncFavorites()?.value
        #expect(directories.favorites == ["/c", "/a"])
        #expect(await remote.updates == [[.add("/b")], [.add("/b")], [.add("/c")]])
    }
}

private actor FavoritesRemote: HostDirectoryRemote {
    struct Unexpected: Error {}

    private(set) var updates: [[DirectoryFavoriteChange]] = []
    private var document: DirectoryFavorites
    private var updateFailure: (any Error)?

    init(_ document: DirectoryFavorites) {
        self.document = document
    }

    func failUpdates(with error: (any Error)?) {
        updateFailure = error
    }

    func readHostInfo() throws -> GatewayClient.HostInfoResponse { throw Unexpected() }

    func readDirectory(path: String) throws -> CodexAppServerV2.FsReadDirectoryResponse { throw Unexpected() }

    func readDirectoryFavorites() -> DirectoryFavorites { document }

    func updateDirectoryFavorites(_ changes: [DirectoryFavoriteChange]) throws -> DirectoryFavorites {
        updates.append(changes)
        if let updateFailure { throw updateFailure }
        document = DirectoryFavorites(revision: document.revision + 1,
                                      paths: changes.reduce(document.paths) { $1.applied(to: $0) })
        return document
    }
}
