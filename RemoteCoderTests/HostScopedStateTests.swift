import Foundation
import Testing
@testable import RemoteCoder

/// Local state that used to be device-wide is now per host. These tests use
/// real defaults suites and real files, because the isolation being asserted is
/// exactly which key and which path a host writes to.
@MainActor
struct HostScopedStateTests {
    @Test func workingDirectoryAndPinsAreKeyedPerHost() {
        let defaults = makeDefaults()
        let mini = UUID()
        let book = UUID()

        HostPreferences.setWorkingDirectory("/Users/developer/mini-repo", hostID: mini, defaults: defaults)
        HostPreferences.setWorkingDirectory("/Users/developer/book-repo", hostID: book, defaults: defaults)
        #expect(HostPreferences.workingDirectory(hostID: mini, defaults: defaults) == "/Users/developer/mini-repo")
        #expect(HostPreferences.workingDirectory(hostID: book, defaults: defaults) == "/Users/developer/book-repo")
        #expect(HostPreferences.workingDirectoryKey(hostID: mini) != HostPreferences.workingDirectoryKey(hostID: book))
        #expect(HostPreferences.workingDirectoryKey(hostID: nil) == "codexWorkingDirectory")

        #expect(ConversationPinStore.storageKey(hostID: nil) == ConversationPinStore.legacyStorageKey)
        #expect(ConversationPinStore.storageKey(hostID: mini) != ConversationPinStore.storageKey(hostID: book))
    }

    @Test func sessionIndexMetadataAndUsageStayOnTheirOwnHost() async throws {
        let mini = UUID()
        let book = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }

        let miniConversation = UUID()
        let bookConversation = UUID()
        await ConversationIndex(hostID: mini, storage: temporary.storage).record(sessionID: "0199", conversationID: miniConversation)
        await ConversationIndex(hostID: book, storage: temporary.storage).record(sessionID: "0199", conversationID: bookConversation)
        // Fresh actors read from disk, so this is file isolation, not memory.
        #expect(await ConversationIndex(hostID: mini, storage: temporary.storage).conversationID(for: "0199") == miniConversation)
        #expect(await ConversationIndex(hostID: book, storage: temporary.storage).conversationID(for: "0199") == bookConversation)

        let metadata = ConversationMetadata(
            sessionID: "0199",
            modelID: "gpt-5.6-sol",
            reasoningSelectionID: "high",
            updatedAt: Date(timeIntervalSince1970: 1_757_500_000)
        )
        try await ConversationMetadataStore(hostID: mini, storage: temporary.storage).save(SessionMetadataLocalState(acknowledged: ["0199": metadata]))
        #expect(try await ConversationMetadataStore(hostID: mini, storage: temporary.storage).load().acknowledged["0199"]?.modelID == "gpt-5.6-sol")
        #expect(try await ConversationMetadataStore(hostID: book, storage: temporary.storage).load().acknowledged.isEmpty)

        let miniVoiceHistory = RealtimeVoiceHistoryStore(hostID: mini, storage: temporary.storage)
        await miniVoiceHistory.append(role: .user, text: "mini call", date: Date(), threadID: "0199")
        await miniVoiceHistory.flush()
        #expect(await RealtimeVoiceHistoryStore(hostID: mini, storage: temporary.storage).entries(for: "0199").count == 1)
        #expect(await RealtimeVoiceHistoryStore(hostID: book, storage: temporary.storage).entries(for: "0199").isEmpty)
    }

    // MARK: - One-shot migration

    @Test func migrationMovesOnlyStateWithOneProvableOwner() async throws {
        let defaults = makeDefaults()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let mini = GatewayHostConfiguration(
            id: UUID(), name: "Mac Mini", hostname: "mini.test", port: 8787, authToken: "t"
        )
        let book = GatewayHostConfiguration(
            id: UUID(), name: "MacBook", hostname: "book.test", port: 8787, authToken: "t"
        )

        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-history-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-storage-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: historyDirectory)
            try? FileManager.default.removeItem(at: legacyDirectory)
        }
        let miniHistory = ConversationHeaderStore(hostID: mini.id, directory: historyDirectory)
        let bookHistory = ConversationHeaderStore(hostID: book.id, directory: historyDirectory)
        await miniHistory.save(
            snapshot: .init(threads: [try thread("mini-only", updatedAt: 10), try thread("on-both", updatedAt: 20)],
            lastSuccessfulRefreshAt: nil, revision: 1))
        await bookHistory.save(
            snapshot: .init(threads: [try thread("on-both", updatedAt: 20)],
            lastSuccessfulRefreshAt: nil, revision: 2))

        // Pre-multi-host state: one unscoped working directory, one pin map and
        // one session-to-conversation index.
        HostPreferences.setWorkingDirectory("/Users/developer/legacy-repo", hostID: nil, defaults: defaults)
        ConversationPinStore.scoped(hostID: nil, defaults: defaults).save([
            "mini-only": "Provable",
            "on-both": "Ambiguous",
            "unknown-thread": "Unknown",
        ])
        let miniConversationID = UUID()
        try writeLegacySessionIndex(
            ["mini-only": miniConversationID, "on-both": UUID(), "unknown-thread": UUID()],
            to: legacyDirectory
        )

        let limitation = HostScopedStateMigration.runIfNeeded(
            hosts: [mini, book],
            activeHostID: mini.id,
            defaults: defaults,
            historyDirectory: historyDirectory,
            legacyStorageDirectory: legacyDirectory,
            storage: temporary.storage
        )

        // The active host owned the single working directory.
        #expect(HostPreferences.workingDirectory(hostID: mini.id, defaults: defaults) == "/Users/developer/legacy-repo")
        #expect(defaults.string(forKey: HostPreferences.workingDirectoryKey(hostID: book.id)) == nil)
        // Legacy values stay put, so a downgrade still finds them.
        #expect(defaults.string(forKey: HostPreferences.workingDirectoryKey(hostID: nil)) == "/Users/developer/legacy-repo")

        let miniPins = ConversationPinStore.scoped(hostID: mini.id, defaults: defaults).load()
        let bookPins = ConversationPinStore.scoped(hostID: book.id, defaults: defaults).load()
        #expect(miniPins == ["mini-only": "Provable"])
        #expect(bookPins.isEmpty)

        // The uniquely owned mapping reaches the host's own index, which is what
        // keeps that chat's persisted timeline attached to it.
        #expect(await ConversationIndex(hostID: mini.id, storage: temporary.storage).conversationID(for: "mini-only") == miniConversationID)
        #expect(await ConversationIndex(hostID: mini.id, storage: temporary.storage).conversationID(for: "on-both") == nil)
        #expect(await ConversationIndex(hostID: book.id, storage: temporary.storage).conversationID(for: "mini-only") == nil)

        // Two owners and no owner are both reported rather than guessed.
        let reported = try #require(limitation)
        #expect(reported.contains("2 pinned chat(s)"))
        #expect(reported.contains("2 session-to-conversation mapping(s)"))

        // Running again must not re-copy anything after the user has edited it.
        defaults.removeObject(forKey: ConversationPinStore.storageKey(hostID: mini.id))
        let second = HostScopedStateMigration.runIfNeeded(
            hosts: [mini, book],
            activeHostID: mini.id,
            defaults: defaults,
            historyDirectory: historyDirectory,
            legacyStorageDirectory: legacyDirectory,
            storage: temporary.storage
        )
        #expect(second == nil)
        #expect(ConversationPinStore.scoped(hostID: mini.id, defaults: defaults).load().isEmpty)
    }

    /// The whole point of running the migration from `ChatWorkspaceModel.init`:
    /// every consumer reads its state once, at construction, so a migration that
    /// landed afterwards would be overwritten by the stores it was meant to seed.
    @Test func migrationCompletesBeforeTheFirstChatModelReadsItsState() async throws {
        let defaults = makeDefaults()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = GatewayHostConfiguration(
            id: UUID(), name: "Mac Mini", hostname: "127.0.0.1", port: 1, authToken: "t"
        )
        HostPreferences.setWorkingDirectory("/Users/developer/legacy-repo", hostID: nil, defaults: defaults)

        let migratedBeforeModel = TestFlag()
        let workspace = ChatWorkspaceModel(
            settings: HostStore(hosts: [host], activeHostID: host.id, defaults: defaults, credentials: MemoryGatewayCredentials()),
            defaults: defaults,
            makeModel: { configuration, preferences, syncedPreferences in
                migratedBeforeModel.value = defaults.string(
                    forKey: HostPreferences.workingDirectoryKey(hostID: configuration.id)
                ) == "/Users/developer/legacy-repo"
                return ChatTargetModel(host: configuration, chatDefaults: defaults, modelPickerPreferences: preferences,
                    syncedPreferences: syncedPreferences,
                    voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: temporary.storage, htmlVisuals: HTMLVisualServices(directory: temporary.storage.root.appending(path: "html-visuals")))
            },
            voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production,
            storage: temporary.storage
        )

        await workspace.finishHostChanges()
        defer { await workspace.retireEverything() }
        #expect(migratedBeforeModel.value)
        #expect(workspace.models.count == 1)

        // And a model constructed after the migration reads exactly that key, so
        // the adopted directory is the one the chat dispatches with.
        HostPreferences.setWorkingDirectory("/Users/developer/legacy-repo", hostID: host.id, defaults: defaults)
        let target = ChatTargetModel(host: host, chatDefaults: defaults, modelPickerPreferences: ModelPickerPreferences(defaults: defaults), syncedPreferences: SyncedPreferenceStore(defaults: defaults, keys: []), voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: temporary.storage, htmlVisuals: HTMLVisualServices(directory: temporary.storage.root.appending(path: "html-visuals")))
        #expect(target.makeScreen(newChat: UUID()).workingDirectory == "/Users/developer/legacy-repo")
    }

    /// R6: the bundled single-machine path is not a fallback for every host.
    @Test func aNewHostGetsNoInheritedDirectoryAndResolvesItsOwnHome() throws {
        let defaults = makeDefaults()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = GatewayHostConfiguration(
            id: UUID(), name: "MacBook", hostname: "127.0.0.1", port: 1, authToken: "t"
        )

        // Even with a bundled `codexWorkdir` present, an unconfigured host has no
        // directory: one machine's repository path is not another's.
        #expect(HostPreferences.workingDirectory(hostID: host.id, defaults: defaults) == nil)

        let target = ChatTargetModel(host: host, chatDefaults: defaults, modelPickerPreferences: ModelPickerPreferences(defaults: defaults), syncedPreferences: SyncedPreferenceStore(defaults: defaults, keys: []), voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: temporary.storage, htmlVisuals: HTMLVisualServices(directory: temporary.storage.root.appending(path: "html-visuals")))
        let model = target.makeScreen(newChat: UUID())
        #expect(model.workingDirectory == nil)

        HostPreferences.setRemoteHomePath("/Users/developer", hostID: host.id, defaults: defaults)
        model.adoptRemoteHomeAsWorkingDirectoryIfUnset()
        #expect(model.workingDirectory == "/Users/developer")

        // A host that already has one keeps it.
        model.updateWorkingDirectory("/Users/developer/repo")
        model.target.remoteHomePath = "/Users/other"
        model.adoptRemoteHomeAsWorkingDirectoryIfUnset()
        #expect(model.workingDirectory == "/Users/developer/repo")
    }

    private func writeLegacySessionIndex(_ entries: [String: UUID], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(
            to: directory.appendingPathComponent("session-index.json", isDirectory: false)
        )
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "HostScopedStateTests.\(UUID().uuidString)") else {
            preconditionFailure("Could not create isolated test defaults")
        }
        return defaults
    }

    private func thread(_ id: String, updatedAt: Int64) throws -> ConversationHeader {
        try ThreadFixture.basic(id, updatedAt: updatedAt)
    }
}
