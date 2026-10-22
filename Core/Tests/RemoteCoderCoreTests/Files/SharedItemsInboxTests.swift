import Foundation
import Testing
@testable import RemoteCoderCore

struct SharedItemsInboxTests {
    private let root = URL.temporaryDirectory.appending(path: "shared-items-\(UUID())")
    private var inbox: SharedItemsInbox { SharedItemsInbox(appGroupContainer: root.appending(path: "group")) }

    private func file(_ name: String, contents: String) throws -> URL {
        let url = root.appending(path: "sources/\(UUID())/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func shares() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).sorted()
    }

    @Test func theAppClaimsAPublishedShareOnceWithItsFilesAndTextInSharedOrder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let share = try inbox.begin(now: .now)
        let temporary = try file("IMG_0001.JPG", contents: "first")
        let owned = try file("IMG_0001.JPG", contents: "second")
        let items = SharedItemsInbox.Items(
            files: [try share.move(temporary, maximumBytes: SharedItemsInbox.maximumBytes), try share.copy(owned, maximumBytes: SharedItemsInbox.maximumBytes)], text: ["https://example.com", "note"])
        try share.publish(items)

        let claim = try await inbox.claim(share.id, into: root.appending(path: "app-tmp"))

        #expect(claim.files.map(\.lastPathComponent) == ["IMG_0001.JPG", "IMG_0001.JPG"])
        #expect(try claim.files.map { try String(contentsOf: $0, encoding: .utf8) } == ["first", "second"])
        #expect(claim.text == ["https://example.com", "note"])
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: owned.path))
        #expect(try shares().isEmpty)
        await #expect(throws: SharedItemsInbox.Unavailable.self) {
            try await inbox.claim(share.id, into: root.appending(path: "app-tmp"))
        }
    }

    @Test func aNewShareRemovesOnlyUnclaimedSharesOlderThanTheirLifetime() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let unclaimed = try inbox.begin(now: .now)
        let recent = try inbox.begin(now: .now)
        #expect(try shares() == [unclaimed.id, recent.id].map(\.uuidString).sorted())

        let later = try inbox.begin(now: .now.addingTimeInterval(SharedItemsInbox.unclaimedLifetime + 60))

        #expect(try shares() == [later.id.uuidString])
    }

    @Test func aLoadThatFinishesAfterTheShareIsDiscardedWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let share = try inbox.begin(now: .now)
        share.discard()

        #expect(throws: (any Error).self) { try share.move(try file("late.mov", contents: "late"), maximumBytes: SharedItemsInbox.maximumBytes) }
        #expect(try shares().isEmpty)
    }
    @Test func oversizedItemsAreRejectedBeforeCopyingOrMoving() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let share = try inbox.begin(now: .now)
        let source = try file("large.dat", contents: "12345")
        #expect(throws: CocoaError.self) { try share.copy(source, maximumBytes: 4) }
        #expect(throws: CocoaError.self) { try share.move(source, maximumBytes: 4) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let contents = try FileManager.default.enumerator(at: share.folder, includingPropertiesForKeys: [.isRegularFileKey])
        let files = (contents?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        #expect(files.isEmpty)
    }

}
