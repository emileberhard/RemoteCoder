import Foundation
import Testing
import Synchronization
@testable import RemoteCoderCore

@MainActor
struct GatewayIdentityTests {
    @Test func verifiedAliasesMergeWithoutGuessingAnUnreachableHost() async throws {
        let suite = "GatewayIdentityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let migration = GatewayIdentityMigration(storage: temporary.storage)
        let first = host("First")
        let second = host("Second")
        let unreachable = host("Away")
        let gateway = UUID()
        let credentials = MemoryGatewayCredentials()
        let store = HostStore(hosts: [first, second, unreachable], activeHostID: second.id,
                              defaults: defaults, credentials: credentials, defaultsDomain: suite)
        defaults.set(["thread": "Pinned"], forKey: ConversationPinStore.storageKey(hostID: first.id))
        defaults.set(["host": first.id.uuidString, "thread": "thread"], forKey: "workspace.open-conversation.v1")
        let identity = GatewayIdentity(hostId: gateway, incarnation: UUID())
        try store.beginIdentityMigration(identity, for: first)
        try await store.completeIdentityMigration(using: migration)
        try store.beginIdentityMigration(identity, for: second)
        try await store.completeIdentityMigration(using: migration)
        let merged = try #require(store.hosts.first { $0.id == gateway })
        #expect(Set(merged.configuration.legacyIDs) == [first.id, second.id])
        #expect(store.hosts.count == 2)
        #expect(store.activeHostID == gateway)
        #expect(store.hosts.first { $0.id == unreachable.id }?.configuration.gatewayID == nil)
        #expect(ConversationPinStore.scoped(hostID: gateway, defaults: defaults).load() == ["thread": "Pinned"])
        #expect(defaults.persistentDomain(forName: suite)?[ConversationPinStore.storageKey(hostID: first.id)] == nil)
        #expect(defaults.dictionary(forKey: "workspace.open-conversation.v1")?["host"] as? String == gateway.uuidString)
        let saved = try HostStore.load(defaults: defaults, credentials: credentials)
        #expect(saved.hosts.first { $0.id == gateway }?.configuration.gatewayID == gateway)
        #expect(store.canonicalHostID(first.id) == gateway)
        ConversationPinStore.scoped(hostID: gateway, defaults: defaults).clear()
        try await store.completeIdentityMigration(using: migration)
        #expect(ConversationPinStore.scoped(hostID: gateway, defaults: defaults).load().isEmpty)
        #expect(throws: (any Error).self) {
            try store.verifyIdentity(.init(hostId: UUID(), incarnation: UUID()), for: merged.configuration)
        }
    }

    @Test func duplicateStateMergesDraftsAndPinsOnce() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let first = UUID(), second = UUID(), gateway = UUID()
        let firstDirectory = temporary.storage.directory(for: .host(first))
        let secondDirectory = temporary.storage.directory(for: .host(second))
        let firstDrafts = ComposerDraftStore(directory: firstDirectory.appending(path: "drafts"))
        let secondDrafts = ComposerDraftStore(directory: secondDirectory.appending(path: "drafts"))
        let firstDraft = try #require(await firstDrafts.draft(for: .thread("same-thread")))
        firstDrafts.document(for: firstDraft).edit(.insert(.init(runs: [.text("First draft")])))
        #expect(await firstDrafts.flush())
        let secondDraft = try #require(await secondDrafts.draft(for: .thread("same-thread")))
        secondDrafts.document(for: secondDraft).edit(.insert(.init(runs: [.text("Second draft")])))
        #expect(await secondDrafts.flush())
        await firstDrafts.retire()
        await secondDrafts.retire()
        var firstMarks = ConversationMarksReplica()
        firstMarks.record(.pin(threadID: "one", name: "One"))
        var secondMarks = ConversationMarksReplica()
        secondMarks.record(.pin(threadID: "two", name: "Two"))
        try JSONEncoder().encode(firstMarks).write(to: firstDirectory.appending(path: ConversationMarksStore.fileName))
        try JSONEncoder().encode(secondMarks).write(to: secondDirectory.appending(path: ConversationMarksStore.fileName))
        let migration = GatewayIdentityMigration(storage: temporary.storage)
        var canonical = host("Canonical")
        canonical.id = gateway
        canonical.gatewayID = gateway
        canonical.legacyIDs = [first]
        let firstImport = GatewayIdentityImport(id: UUID(), host: canonical, replacedIDs: [first])
        try await migration.migrate(firstImport)
        canonical.legacyIDs = [second]
        let secondImport = GatewayIdentityImport(id: UUID(), host: canonical, replacedIDs: [second])
        try await migration.migrate(secondImport)
        try await migration.migrate(secondImport)
        let target = temporary.storage.directory(for: .host(gateway))
        let reopened = ComposerDraftStore(directory: target.appending(path: "drafts"))
        let merged = try #require(await reopened.draft(for: .thread("same-thread")))
        #expect(reopened.document(for: merged).content.expandedText == "First draft\n\nSecond draft")
        let marks = try JSONDecoder().decode(ConversationMarksReplica.self,
            from: Data(contentsOf: target.appending(path: ConversationMarksStore.fileName)))
        #expect(marks.effective.pinNames == ["one": "One", "two": "Two"])
        #expect(Set(marks.pending.map(\.id)) == Set(firstMarks.pending.map(\.id) + secondMarks.pending.map(\.id)))
        await reopened.retire()
        let recording = temporary.storage.root.appending(path: "dictation-recordings/\(UUID())/recording.json")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "owner": ["hostID": second.uuidString], "sampleRate": 16_000])
            .write(to: recording)
        try await migration.finish(secondImport)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: recording)) as? [String: Any]
        #expect((manifest?["owner"] as? [String: String])?["hostID"] == gateway.uuidString)
        #expect(!FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    @Test func syncedIdentityKeepsALocalAliasUntilItsStateCanBeMigrated() throws {
        let legacy = host("Legacy")
        var canonical = legacy
        canonical.id = UUID()
        canonical.gatewayID = canonical.id
        canonical.legacyIDs = [legacy.id]
        var remote = HostDirectory()
        remote.record(canonical, at: .now)
        let unresolved = try #require(remote.configurations(updating: [legacy]).first)
        #expect(unresolved.id == legacy.id)
        #expect(unresolved.gatewayID == canonical.id)
        #expect(unresolved.legacyIDs == [canonical.id])
        remote.adopt([unresolved])
        #expect(remote.entries.count == 1)
    }

    @Test func aFailedCredentialSaveLeavesIdentityUnchanged() async throws {
        let suite = "GatewayIdentityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = host("Original")
        let credentials = MemoryGatewayCredentials()
        let store = HostStore(hosts: [original], activeHostID: original.id, defaults: defaults, credentials: credentials, defaultsDomain: suite)
        credentials.fail(with: -50)
        #expect(throws: (any Error).self) { try store.beginIdentityMigration(.init(hostId: UUID(), incarnation: UUID()), for: original) }
        #expect(store.identityMigrationHostIDs.contains(original.id))
        #expect(store.hosts.first?.configuration == original)
    }

    @Test func canonicalHostsNeverStartLaunchIdentityReads() async {
        var canonical = host("Canonical")
        canonical.gatewayID = canonical.id
        let identity = GatewayIdentity(hostId: UUID(), incarnation: UUID())
        var reads = 0
        let resolved = await GatewayIdentityLaunch.read(hosts: [canonical], budget: .seconds(2)) { _ in
            reads += 1
            return identity
        }
        #expect(reads == 0)
        #expect(resolved.isEmpty)
    }

    @Test func anExpiredLaunchBudgetLeavesLegacyHostsUnresolvedWithoutReading() async {
        let legacy = host("Legacy")
        let identity = GatewayIdentity(hostId: UUID(), incarnation: UUID())
        var reads = 0
        let resolved = await GatewayIdentityLaunch.read(hosts: [legacy], budget: .zero) { _ in
            reads += 1
            return identity
        }
        #expect(reads == 0)
        #expect(resolved.isEmpty)
    }

    @Test func preferencesOnlyMigrateOwnedPersistentValuesAndRetireRenamedKeys() async throws {
        let suite = "GatewayIdentityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = UUID(), target = UUID()
        let oldKey = "pins.\(source)", newKey = "pins.\(target)"
        let registeredKey = "registered.\(source)"
        defaults.register(defaults: [registeredKey: ["host": source.uuidString]])
        defaults.set(["old": "retained", "same": "older"], forKey: oldKey)
        defaults.set(["same": "newer", "host": source.uuidString], forKey: newKey)
        try await GatewayIdentityPreferences.migrate(from: source, to: target, domainName: suite)
        let saved = try #require(defaults.persistentDomain(forName: suite))
        #expect(saved[oldKey] == nil)
        #expect(saved[newKey] as? [String: String] == ["old": "retained", "same": "newer", "host": target.uuidString])
        #expect(saved[registeredKey] == nil)
        #expect(saved["registered.\(target)"] == nil)
        #expect(defaults.dictionary(forKey: registeredKey)?["host"] as? String == source.uuidString)
        defaults.removeObject(forKey: newKey)
        try await GatewayIdentityPreferences.migrate(from: source, to: target, domainName: suite)
        #expect(defaults.persistentDomain(forName: suite)?[newKey] == nil)
    }

    @Test(arguments: [IdentitySaveFailure.adoption, .completion])
    func journalResumesOfflineAcrossCredentialSaveFailures(failure: IdentitySaveFailure) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let suite = "GatewayIdentityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = host("Source"), target = UUID(), older = UUID()
        var duplicate = host("Duplicate")
        duplicate.gatewayID = target
        duplicate.legacyIDs = [older]
        let credentials = IdentityJournalCredentials(target: target, failure: failure)
        let before = HostStore(hosts: [source, duplicate], activeHostID: source.id,
                               defaults: defaults, credentials: credentials, defaultsDomain: suite)
        let originalDirectory = temporary.storage.directory(for: .host(source.id))
        let drafts = ComposerDraftStore(directory: originalDirectory.appending(path: "drafts"))
        let draft = try #require(await drafts.draft(for: .thread("thread")))
        drafts.document(for: draft).edit(.insert(.init(runs: [.text("Saved draft")])))
        #expect(await drafts.flush())
        await drafts.retire()
        let conversationID = UUID()
        let originalCheckpoints = ConversationCheckpointStore(hostID: source.id, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: conversationID, threadID: "thread")
        state.appendLocal(ChatMessage(role: .codex, text: "Saved answer"), turnID: "turn")
        try await originalCheckpoints.save(state.checkpoint, conversationID: conversationID)
        defaults.set(["thread": "Pinned"], forKey: ConversationPinStore.storageKey(hostID: source.id))
        defaults.set(["host": source.id.uuidString, "thread": "thread"], forKey: "workspace.open-conversation.v1")
        let recording = temporary.storage.root.appending(path: "dictation-recordings/recording/recording.json")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["owner": ["hostID": source.id.uuidString]]).write(to: recording)
        try before.beginIdentityMigration(.init(hostId: target, incarnation: UUID()), for: source)
        let journal = try #require(before.identityMigration)
        #expect(Set(journal.host.legacyIDs) == [source.id, duplicate.id, older])
        #expect(before.identityMigrationHostIDs == [source.id, duplicate.id, older, target])
        let migration = GatewayIdentityMigration(storage: temporary.storage)
        await #expect(throws: (any Error).self) { try await before.completeIdentityMigration(using: migration) }
        #expect(before.identityMigration == journal)
        credentials.allowCompletion()
        let reopened = HostStore(defaults: defaults, credentials: credentials, sharedDirectory: MemoryGatewayCredentials(),
            configuration: .success(LocalConfiguration()), defaultsDomain: suite)
        #expect(reopened.identityMigration == journal)
        #expect(reopened.identityMigrationHostIDs == [source.id, duplicate.id, older, target])
        #expect(!reopened.upsert(source))
        let restarted = GatewayIdentityMigration(storage: temporary.storage)
        try await reopened.completeIdentityMigration(using: restarted)
        #expect(reopened.identityMigration == nil)
        #expect(reopened.identityMigrationHostIDs.isEmpty)
        #expect(reopened.hosts.map(\.id) == [target])
        #expect(ConversationPinStore.scoped(hostID: target, defaults: defaults).load() == ["thread": "Pinned"])
        #expect(defaults.persistentDomain(forName: suite)?[ConversationPinStore.storageKey(hostID: source.id)] == nil)
        #expect(defaults.dictionary(forKey: "workspace.open-conversation.v1")?["host"] as? String == target.uuidString)
        let destinationDrafts = ComposerDraftStore(directory: temporary.storage.directory(for: .host(target)).appending(path: "drafts"))
        let restoredDraft = try #require(await destinationDrafts.draft(for: .thread("thread")))
        #expect(destinationDrafts.document(for: restoredDraft).content.expandedText == "Saved draft")
        await destinationDrafts.retire()
        let destinationCheckpoints = ConversationCheckpointStore(hostID: target, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        #expect(try await destinationCheckpoints.load(conversationID, threadID: "thread")?.threadID == "thread")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recording)) as? [String: Any])
        #expect((manifest["owner"] as? [String: String])?["hostID"] == target.uuidString)
        #expect(!FileManager.default.fileExists(atPath: originalDirectory.path))
        defaults.removeObject(forKey: ConversationPinStore.storageKey(hostID: target))
        try await reopened.completeIdentityMigration(using: restarted)
        #expect(ConversationPinStore.scoped(hostID: target, defaults: defaults).load().isEmpty)
    }

    private func host(_ name: String) -> GatewayHostConfiguration {
        .init(id: UUID(), name: name, hostname: "\(name.lowercased()).example", port: 443, authToken: "fixture")
    }
}

enum IdentitySaveFailure: Equatable, Sendable { case adoption, completion }

private final class IdentityJournalCredentials: GatewayCredentialStorage {
    private struct State { var data: Data?; var reject = true }
    private let state = Mutex(State())
    private let target: UUID
    private let failure: IdentitySaveFailure
    init(target: UUID, failure: IdentitySaveFailure) { self.target = target; self.failure = failure }
    func read() -> Data? { state.withLock { $0.data } }
    func allowCompletion() { state.withLock { $0.reject = false } }
    func write(_ data: Data) throws {
        struct Snapshot: Decodable { let hosts: [GatewayHostConfiguration]; let identityMigration: GatewayIdentityImport? }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        try state.withLock { value in
            if value.reject, snapshot.hosts.contains(where: { $0.id == target }),
               failure == .adoption || snapshot.identityMigration == nil { throw CocoaError(.fileWriteNoPermission) }
            value.data = data
        }
    }
}
