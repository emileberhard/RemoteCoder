import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct HostSyncTests {
    private let miniID = UUID()
    private let bookID = UUID()

    private func host(_ id: UUID, _ name: String, token: String) -> GatewayHostConfiguration {
        GatewayHostConfiguration(id: id, name: name, hostname: "\(name.lowercased()).example", port: 8787,
            authToken: token, transport: .trustedNetwork)
    }

    private final class Device {
        let defaults: UserDefaults
        let suite = "HostSyncTests.\(UUID())"
        let local = MemoryGatewayCredentials()

        init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
        deinit { defaults.removePersistentDomain(forName: suite) }

        @MainActor func savePreSyncHosts(_ hosts: [GatewayHostConfiguration]) throws {
            try HostStore.save(hosts: hosts, activeHostID: hosts.first?.id, directory: HostDirectory(), defaults: defaults,
                credentials: local)
        }

        @MainActor func open(sharing shared: MemoryGatewayCredentials,
                             configuration: LocalConfiguration = LocalConfiguration()) async -> HostStore {
            let store = HostStore(defaults: defaults, credentials: local, sharedDirectory: shared,
                configuration: .success(configuration))
            await store.synchronize()
            return store
        }
    }

    private func tokens(_ store: HostStore) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: (store.hosts.map(\.configuration) + store.invalidHosts).map { ($0.id, $0.authToken) })
    }

    @Test func aDeviceMissingAHostAddsItInsteadOfDeletingItElsewhere() async throws {
        let shared = MemoryGatewayCredentials()
        let phone = try Device()
        let mac = try Device()
        try mac.savePreSyncHosts([host(miniID, "Mini", token: "rc1.mac.mini")])
        try phone.savePreSyncHosts([host(miniID, "Mini", token: "rc1.phone.mini"), host(bookID, "Book", token: "rc1.phone.book")])

        let macStore = await mac.open(sharing: shared)
        let phoneStore = await phone.open(sharing: shared)
        await macStore.synchronize()

        #expect(phoneStore.hosts.map(\.id) == [miniID, bookID])
        #expect(tokens(phoneStore) == [miniID: "rc1.phone.mini", bookID: "rc1.phone.book"])
        #expect(macStore.hosts.map(\.id) == [miniID])
        #expect(macStore.invalidHosts.map(\.id) == [bookID])
        #expect(tokens(macStore) == [miniID: "rc1.mac.mini", bookID: ""])
        #expect(macStore.syncFailure == nil)
    }

    @Test func anOperatorCredentialSyncsSoEachDeviceEnrollsItsOwnInstallation() async throws {
        let shared = MemoryGatewayCredentials()
        let phone = try Device()
        let mac = try Device()
        try phone.savePreSyncHosts([host(bookID, "Book", token: "rc1.phone.book")])
        try mac.savePreSyncHosts([host(miniID, "Mini", token: "rc1.mac.mini")])
        let phoneStore = await phone.open(sharing: shared)
        let macStore = await mac.open(sharing: shared)

        var repaired = try #require(macStore.invalidHosts.first { $0.id == bookID })
        repaired.authToken = "synthetic-operator"
        #expect(macStore.upsert(repaired))
        await macStore.synchronize()
        let tabletStore = await (try Device()).open(sharing: shared)
        await phoneStore.synchronize()

        #expect(tokens(tabletStore) == [miniID: "", bookID: "synthetic-operator"])
        #expect(tokens(phoneStore)[bookID] == "rc1.phone.book")

        await macStore.enrollInstallationCredentials(using: SyntheticEnrollment()) { _ in true }
        #expect(tokens(macStore)[bookID]?.hasPrefix("rc1.") == true)
        await tabletStore.synchronize()
        #expect(tokens(tabletStore)[bookID] == "synthetic-operator")
    }

    @Test func aRolloutTieKeepsTheOperatorCredentialOneDeviceStillHolds() async throws {
        let shared = MemoryGatewayCredentials()
        let phone = try Device()
        let mac = try Device()
        try phone.savePreSyncHosts([host(miniID, "Mini", token: "rc1.phone.mini")])
        try mac.savePreSyncHosts([host(miniID, "Mini", token: "synthetic-operator")])

        _ = await phone.open(sharing: shared)
        _ = await mac.open(sharing: shared)
        let tabletStore = await (try Device()).open(sharing: shared)

        #expect(tokens(tabletStore) == [miniID: "synthetic-operator"])
    }

    @Test func anEndpointChangeNeverCarriesACredentialToTheNewEndpoint() async throws {
        let shared = MemoryGatewayCredentials()
        let phone = try Device()
        let mac = try Device()
        try phone.savePreSyncHosts([host(miniID, "Mini", token: "rc1.phone.mini")])
        try mac.savePreSyncHosts([host(miniID, "Mini", token: "synthetic-operator")])
        let phoneStore = await phone.open(sharing: shared)
        let macStore = await mac.open(sharing: shared)

        var moved = try #require(phoneStore.hosts.first).configuration
        moved.hostname = "moved.example"
        #expect(phoneStore.upsert(moved))
        await phoneStore.synchronize()
        await macStore.synchronize()

        #expect(phoneStore.hosts.first?.authToken == "rc1.phone.mini")
        #expect(macStore.invalidHosts.map(\.hostname) == ["moved.example"])
        #expect(tokens(macStore) == [miniID: ""])
    }

    @Test func onlyAnExplicitDeletionRemovesAHostAndLateDevicesCannotRestoreIt() async throws {
        let shared = MemoryGatewayCredentials()
        let phone = try Device()
        let mac = try Device()
        let lagging = try Device()
        let hosts = [host(miniID, "Mini", token: "rc1.mini"), host(bookID, "Book", token: "rc1.book")]
        try phone.savePreSyncHosts(hosts)
        try mac.savePreSyncHosts(hosts)
        try lagging.savePreSyncHosts(hosts)
        let phoneStore = await phone.open(sharing: shared)
        let macStore = await mac.open(sharing: shared)

        #expect(phoneStore.delete(hosts[1]))
        await phoneStore.synchronize()
        await macStore.synchronize()
        let laggingStore = await lagging.open(sharing: shared)

        #expect(macStore.hosts.map(\.id) == [miniID])
        #expect(laggingStore.hosts.map(\.id) == [miniID])
        await phoneStore.synchronize()
        #expect(phoneStore.hosts.map(\.id) == [miniID])
    }

    @Test func discoveringACredentialIsNotAnEditThatOutranksADeletion() {
        let configuration = LocalConfiguration(macMiniHostname: "mini.example", codexGatewayPort: 8787,
            codexGatewayAuthToken: "synthetic-operator")
        guard let seed = GatewayHostConfiguration.builtInDefaults(from: configuration).first else {
            Issue.record("The configuration has no seed host")
            return
        }
        var enrolled = seed
        enrolled.authToken = "rc1.stale.mini"
        var stale = HostDirectory()
        stale.adopt([enrolled])
        stale.fillEnrollmentCredentials(from: [seed])
        var deleting = HostDirectory()
        deleting.adopt([enrolled])
        deleting.remove(seed.id, at: .now)

        #expect(stale.entries.map(\.enrollmentToken) == ["synthetic-operator"])
        #expect(stale.entries.map(\.modifiedAt) == [.distantPast])
        #expect(stale.merged(with: deleting).entries.isEmpty)
        #expect(deleting.merged(with: stale).entries.isEmpty)
    }

    @Test func theNewestEditWinsAndKeepsEachDevicesInstallationCredential() async throws {
        let shared = MemoryGatewayCredentials()
        let phone = try Device()
        let mac = try Device()
        try phone.savePreSyncHosts([host(miniID, "Mini", token: "rc1.phone.mini")])
        try mac.savePreSyncHosts([host(miniID, "Mini", token: "rc1.mac.mini")])
        let phoneStore = await phone.open(sharing: shared)
        let macStore = await mac.open(sharing: shared)

        var renamed = try #require(phoneStore.hosts.first).configuration
        renamed.name = "Living Room Mini"
        #expect(phoneStore.upsert(renamed))
        await phoneStore.synchronize()
        await macStore.synchronize()

        #expect(macStore.hosts.first?.name == "Living Room Mini")
        #expect(macStore.hosts.first?.authToken == "rc1.mac.mini")
    }

    @Test func aDirectoryFromANewerAppIsNeitherMergedNorOverwritten() async throws {
        let shared = MemoryGatewayCredentials()
        let newer = Data(#"{"version":2,"entries":[],"deletions":[]}"#.utf8)
        try shared.write(newer)
        let phone = try Device()
        try phone.savePreSyncHosts([host(miniID, "Mini", token: "rc1.phone.mini")])

        let store = await phone.open(sharing: shared)

        #expect(store.hosts.map(\.id) == [miniID])
        #expect(store.syncFailure != nil)
        #expect(try shared.read() == newer)
        let directory = SharedHostDirectory(storage: shared)
        await #expect(throws: HostDirectory.UnsupportedVersion.self) { try await directory.replace(nil, with: HostDirectory()) }
        #expect(try shared.read() == newer)
    }

    @Test func aDirectoryChangedSinceItWasReadIsNotReplaced() async throws {
        let shared = MemoryGatewayCredentials()
        let directory = SharedHostDirectory(storage: shared)
        var current = HostDirectory()
        current.record(host(miniID, "Mini", token: "rc1.mini"), at: .now)
        #expect(try await directory.replace(nil, with: current))

        #expect(try await directory.replace(nil, with: HostDirectory()) == false)
        #expect(try await directory.read() == current)
    }

    @Test func aDevelopmentSeedSuppliesTheMissingEnrollmentCredential() async throws {
        let shared = MemoryGatewayCredentials()
        let configuration = LocalConfiguration(macMiniHostname: "mini.example", codexGatewayPort: 8787,
            codexGatewayAuthToken: "synthetic-operator")
        let seed = try #require(GatewayHostConfiguration.builtInDefaults(from: configuration).first)
        let tablet = try Device()
        var enrolled = seed
        enrolled.authToken = "rc1.tablet.mini"
        try tablet.savePreSyncHosts([enrolled])

        _ = await tablet.open(sharing: shared, configuration: configuration)
        let macStore = await (try Device()).open(sharing: shared)

        #expect(tokens(macStore) == [seed.id: "synthetic-operator"])
    }
}

private struct SyntheticEnrollment: GatewayCredentialEnrolling {
    func enroll(host: GatewayHostConfiguration, installationID: String) async throws -> String {
        "rc1.\(installationID).synthetic"
    }
}
