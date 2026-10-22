import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct GatewayHostStorageTests {
    @Test func defaultHostsAreUsableWithoutPrivateLocalConfig() throws {
        let configuration = try LocalConfiguration.load()
        let hosts = GatewayHostConfiguration.builtInDefaults(from: configuration)

        #expect(!hosts.isEmpty)
        #expect(hosts.allSatisfy { $0.port == (configuration.codexGatewayPort ?? 8787) })

        let macMiniHostname = configuration.macMiniHostname ?? ""
        let macBookHostname = configuration.macBookHostname ?? ""
        if macMiniHostname.isEmpty && macBookHostname.isEmpty {
            #expect(hosts.map(\.name) == ["Local Gateway"])
            #expect(hosts.map(\.hostname) == ["127.0.0.1"])
        } else {
            #expect(hosts.map(\.hostname) == [macMiniHostname, macBookHostname].filter { !$0.isEmpty })
        }
    }

    @Test func deletedBuiltInHostStaysDeleted() throws {
        let suiteName = "GatewayHostStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let originalHost = GatewayHostConfiguration(
            id: UUID(), name: "Existing Mac", hostname: "custom.example", port: 8787, authToken: "existing-token"
        )
        let credentials = MemoryGatewayCredentials()
        try HostStore.save(hosts: [originalHost], activeHostID: originalHost.id, directory: HostDirectory(),
            defaults: defaults, credentials: credentials)

        let loaded = try HostStore.load(defaults: defaults, credentials: credentials)

        #expect(loaded.activeHostID == originalHost.id)
        #expect(loaded.hosts.map(\.configuration) == [originalHost])
        #expect(loaded.invalidHosts.isEmpty)
    }

    @Test func invalidStoredHostIsReportedWithoutRemovingValidHosts() throws {
        let suiteName = "GatewayHostStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = MemoryGatewayCredentials()
        let valid = GatewayHostConfiguration(id: UUID(), name: "Valid", hostname: "valid.example", port: 443,
            authToken: "fixture-token")
        let invalid = GatewayHostConfiguration(id: UUID(), name: "Invalid", hostname: "bad/path", port: 443,
            authToken: "fixture-token")
        try HostStore.save(hosts: [invalid, valid], activeHostID: invalid.id, directory: HostDirectory(), defaults: defaults,
            credentials: credentials)

        let loaded = try HostStore.load(defaults: defaults, credentials: credentials)

        #expect(loaded.hosts.map(\.configuration) == [valid])
        #expect(loaded.activeHostID == valid.id)
        #expect(loaded.invalidHosts == [invalid])
    }

    @Test func malformedBundledLocalConfigThrowsInsteadOfSilentlyDefaulting() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LocalConfigurationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not valid json".utf8).write(to: directory.appending(path: "RemoteCoderLocalConfig.json"))
        let bundle = try #require(Bundle(url: directory))

        #expect(throws: (any Error).self) { try LocalConfiguration.load(bundle: bundle) }
    }

    @MainActor @Test func invalidStoredHostSurvivesSavesUntilRepairedOrDeleted() throws {
        let suiteName = "GatewayHostStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = MemoryGatewayCredentials()
        let valid = GatewayHostConfiguration(id: UUID(), name: "Valid", hostname: "valid.example", port: 443,
            authToken: "fixture-token")
        let invalid = GatewayHostConfiguration(id: UUID(), name: "Invalid", hostname: "bad/path", port: 443,
            authToken: "fixture-token")
        let added = GatewayHostConfiguration(id: UUID(), name: "Added", hostname: "added.example", port: 443,
            authToken: "fixture-token")
        let store = HostStore(hosts: [valid], activeHostID: valid.id, defaults: defaults, credentials: credentials)
        try HostStore.save(hosts: [invalid, valid], activeHostID: valid.id, directory: HostDirectory(), defaults: defaults,
            credentials: credentials)
        store.reload()

        #expect(store.upsert(added))
        #expect(try HostStore.load(defaults: defaults, credentials: credentials).invalidHosts == [invalid])

        var repaired = invalid
        repaired.hostname = "repaired.example"
        #expect(store.upsert(repaired))
        #expect(store.invalidHosts.isEmpty)
        #expect(try HostStore.load(defaults: defaults, credentials: credentials).hosts.map(\.configuration) == [repaired, valid, added])

        try HostStore.save(hosts: [invalid, valid], activeHostID: valid.id, directory: HostDirectory(), defaults: defaults,
            credentials: credentials)
        store.reload()
        #expect(store.delete(invalid))
        #expect(try HostStore.load(defaults: defaults, credentials: credentials).invalidHosts.isEmpty)
    }
}
