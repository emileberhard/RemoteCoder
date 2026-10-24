import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct HostInformationTests {
    @Test func capabilitiesRefreshWithTheRemoteHomeAfterReconnection() async throws {
        let suite = "HostInformationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = InformationRemote(.init(homeDirectory: "/home/first", hostname: "workstation",
                                            automationsAuthority: "workstation", speechAvailable: true))
        let hostID = UUID()
        let directories = HostDirectories(gateway: remote, hostID: hostID, hostLabel: "Test", defaults: defaults)
        #expect(directories.lastKnownHomePath == nil)
        #expect(try await directories.resolveHomePath() == "/home/first")
        #expect(directories.information?.automationsAuthority == "workstation")
        await remote.replace(.init(homeDirectory: "/home/second", hostname: "workstation", speechAvailable: false))
        directories.connectionChanged()
        #expect(directories.information == nil)
        #expect(try await directories.resolveHomePath() == "/home/second")
        #expect(directories.information?.automationsAuthority == nil)
        #expect(directories.information?.speechAvailable == false)
        #expect(await remote.reads == 2)
        await directories.retire()

        let relaunched = HostDirectories(gateway: remote, hostID: hostID, hostLabel: "Test", defaults: defaults)
        #expect(relaunched.lastKnownHomePath == "/home/second")
        #expect(relaunched.home == .unresolved)
        #expect(await remote.reads == 2)
    }

    @Test func aReconnectDuringResolutionResolvesOnTheNewConnection() async throws {
        let suite = "HostInformationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = HeldFirstReadRemote(homes: ["/home/before", "/home/after"])
        let directories = HostDirectories(gateway: remote, hostID: UUID(), hostLabel: "Test", defaults: defaults)
        let resolution = Task { try await directories.resolveHomePath() }
        await remote.firstReadArrived()
        directories.connectionChanged()
        await remote.releaseFirstRead()
        #expect(try await resolution.value == "/home/after")
        #expect(directories.home == .resolved("/home/after"))
        #expect(directories.lastKnownHomePath == "/home/after")
        await directories.retire()
    }

    @Test func legacyGatewayDoesNotInventCapabilities() throws {
        let information = try JSONDecoder().decode(GatewayClient.HostInfoResponse.self,
            from: Data(#"{"homeDirectory":"/home/user"}"#.utf8))
        #expect(information.hostname == nil)
        #expect(information.automationsAuthority == nil)
        #expect(information.speechAvailable == nil)
    }
}

private actor InformationRemote: HostDirectoryRemote {
    private var information: GatewayClient.HostInfoResponse
    private(set) var reads = 0
    init(_ information: GatewayClient.HostInfoResponse) { self.information = information }
    func replace(_ information: GatewayClient.HostInfoResponse) { self.information = information }
    func readHostInfo() -> GatewayClient.HostInfoResponse { reads += 1; return information }
    func readDirectory(path: String) throws -> CodexAppServerV2.FsReadDirectoryResponse { throw CocoaError(.featureUnsupported) }
    func readDirectoryFavorites() -> DirectoryFavorites { DirectoryFavorites(revision: 0, paths: []) }
    func updateDirectoryFavorites(_ changes: [DirectoryFavoriteChange]) throws -> DirectoryFavorites { throw CocoaError(.featureUnsupported) }
}

private actor HeldFirstReadRemote: HostDirectoryRemote {
    private var homes: [String]
    private var heldRead: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    init(homes: [String]) { self.homes = homes }

    func readHostInfo() async -> GatewayClient.HostInfoResponse {
        let home = homes.removeFirst()
        if home == "/home/before" {
            await withCheckedContinuation { heldRead = $0; arrivalWaiter?.resume(); arrivalWaiter = nil }
        }
        return .init(homeDirectory: home)
    }

    func firstReadArrived() async {
        guard heldRead == nil else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func releaseFirstRead() { heldRead?.resume(); heldRead = nil }
    func readDirectory(path: String) throws -> CodexAppServerV2.FsReadDirectoryResponse { throw CocoaError(.featureUnsupported) }
    func readDirectoryFavorites() -> DirectoryFavorites { DirectoryFavorites(revision: 0, paths: []) }
    func updateDirectoryFavorites(_ changes: [DirectoryFavoriteChange]) throws -> DirectoryFavorites { throw CocoaError(.featureUnsupported) }
}
