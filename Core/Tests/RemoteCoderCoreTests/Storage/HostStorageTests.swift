import Foundation
import Testing
@testable import RemoteCoderCore

struct HostStorageTests {
    @Test func existingDeviceHostAndAccountPathsStayStable() throws {
        let host = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let account = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let root = URL.applicationSupportDirectory.appending(path: "RemoteCoder")
        #expect(HostStorage.live.directory(for: .device).path == root.path)
        #expect(HostStorage.live.directory(for: .host(host)).path == root.appending(path: "hosts/\(host.uuidString)").path)
        #expect(HostStorage.live.directory(for: .account(host: host, account: account)).path
            == root.appending(path: "hosts/\(host.uuidString)/accounts/\(account.uuidString)").path)
    }

    @Test func eachHostAndAccountGetsItsOwnDirectoryUnderTheSharedRoot() {
        let mini = UUID()
        let book = UUID()
        let fixture = TemporaryHostStorage()
        let miniDirectory = fixture.storage.directory(for: .host(mini))
        let bookDirectory = fixture.storage.directory(for: .host(book))

        #expect(miniDirectory != bookDirectory)
        #expect(miniDirectory.lastPathComponent == mini.uuidString)
        #expect(miniDirectory.deletingLastPathComponent().lastPathComponent == "hosts")
        // The legacy unscoped root is still addressable, for migration only.
        let legacy = fixture.storage.directory(for: .device)
        #expect(legacy.lastPathComponent.hasPrefix("RemoteCoderCoreTests-"))
        #expect(miniDirectory.path.hasPrefix(legacy.path))

        let accountA = fixture.storage.directory(for: .account(host: mini, account: UUID()))
        let accountB = fixture.storage.directory(for: .account(host: mini, account: UUID()))
        #expect(Set([miniDirectory, accountA, accountB]).count == 3)
    }
}
