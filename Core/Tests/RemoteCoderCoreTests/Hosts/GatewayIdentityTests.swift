import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct GatewayIdentityTests {
    @Test func verifiedAliasesMergeWithoutGuessingAnUnreachableHost() async throws {
        let suite = "GatewayIdentityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
        try await store.adoptIdentity(identity, for: first)
        try await store.adoptIdentity(identity, for: second)
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
        try await store.adoptIdentity(identity, for: merged.configuration)
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
        try await migration.migrate(from: first, to: gateway)
        try await migration.migrate(from: second, to: gateway)
        try await migration.migrate(from: second, to: gateway)
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
        try await migration.finish(from: second, to: gateway)
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
        await #expect(throws: (any Error).self) { try await store.adoptIdentity(.init(hostId: UUID(), incarnation: UUID()), for: original) }
        #expect(store.hosts.first?.configuration == original)
    }

    @Test func launchSkipsCanonicalHostsAndCancelsUnresolvedReadsAtTheSharedDeadline() async throws {
        var canonical = host("Canonical")
        canonical.gatewayID = canonical.id
        let ready = host("Ready"), away = host("Away")
        let identity = GatewayIdentity(hostId: UUID(), incarnation: UUID())
        var reads: Set<UUID> = []
        var cancelled = false
        let resolved = await GatewayIdentityLaunch.read(hosts: [canonical, ready, away], budget: .milliseconds(25)) { host in
            reads.insert(host.id)
            if host.id == away.id {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = true; throw error }
            }
            return identity
        }
        #expect(reads == [ready.id, away.id])
        #expect(resolved.map { $0.0.id } == [ready.id])
        #expect(resolved.first?.1 == identity)
        #expect(cancelled)
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

    private func host(_ name: String) -> GatewayHostConfiguration {
        .init(id: UUID(), name: name, hostname: "\(name.lowercased()).example", port: 443, authToken: "fixture")
    }
}
