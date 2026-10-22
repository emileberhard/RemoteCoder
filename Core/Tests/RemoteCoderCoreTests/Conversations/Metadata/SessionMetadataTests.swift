import Foundation
import Testing
@testable import RemoteCoderCore

struct SessionMetadataTests {
    @Test func carriedSettingsSurviveOlderReadsAndRelaunchWithoutReadingTheMetadataDocument() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        var old = record("chat", model: "gpt-6-astra", revision: 1)
        old.reasoningSelectionID = "automatic"
        old.fastModeEnabled = true
        try await fixture.store.save(.init(acknowledged: ["chat": old]))
        await fixture.remote.configure(entries: ["chat": old], holdRead: true)
        let older = Task { await fixture.service.sync() }
        await fixture.remote.waitForRead()
        let observation = try JSONDecoder().decode(CodexAppServerV2.ThreadSettingsUpdatedNotification.self,
            from: Data(#"{"threadId":"chat","threadSettings":{"model":"gpt-6-astra","effort":"high"}}"#.utf8))
        let receivedAt = Date(timeIntervalSince1970: 200)
        await fixture.service.observeSettings(observation, observedAt: receivedAt)
        await fixture.remote.releaseRead()
        await older.value
        let observed = try #require(await fixture.service.metadata(for: "chat"))
        #expect(observed.reasoningSelectionID == "effort-high")
        #expect(observed.fastModeEnabled == true)
        #expect(try await fixture.store.load().observed?["chat"]?.metadata.fastModeEnabled == nil)
        #expect(observed.serverRevision == nil)
        #expect(observed.mutationID == nil)
        #expect(observed.source == nil)
        #expect(observed.updatedAt == receivedAt)
        #expect(await fixture.remote.readCount == 1)
        #expect(await fixture.remote.appliedCount == 0)
        #expect(try await fixture.store.load().acknowledged["chat"] == old)
        await fixture.service.retire()
        await fixture.remote.failReads(true)
        let restored = ConversationMetadataService(remote: fixture.remote, store: fixture.store)
        defer { await restored.retire() }
        #expect(await restored.metadata(for: "chat") == observed)
        #expect(await fixture.remote.readCount == 1)
    }

    @Test func aRuntimeObservationWithoutMetadataLearnsARevisionBeforeReconcilingANewerPreference() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        let notification = try JSONDecoder().decode(CodexAppServerV2.ThreadSettingsUpdatedNotification.self,
            from: Data(#"{"threadId":"chat","threadSettings":{"model":"gpt-6-astra","effort":"high","serviceTier":null}}"#.utf8))
        await fixture.service.observeSettings(notification, observedAt: Date(timeIntervalSince1970: 100))
        #expect(try await fixture.store.load().observed?["chat"]?.acknowledgedRevision == nil)
        var automatic = record("chat", model: "gpt-6-astra", revision: 1)
        automatic.reasoningSelectionID = "automatic"
        await fixture.remote.configure(entries: ["chat": automatic])
        await fixture.service.sync()
        #expect(try await fixture.store.load().observed?["chat"]?.acknowledgedRevision == 1)
        #expect(await fixture.service.metadata(for: "chat")?.reasoningSelectionID == "effort-high")
        automatic.serverRevision = 2
        await fixture.remote.configure(entries: ["chat": automatic])
        await fixture.service.sync()
        #expect(await fixture.service.metadata(for: "chat") == automatic)
        #expect(try await fixture.store.load().observed?["chat"] == nil)
    }

    @Test func aFreshNewerMetadataRevisionReplacesAnOlderObservedEffortWithAutomatic() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        let old = record("chat", model: "gpt-6-astra", revision: 1)
        try await fixture.store.save(.init(acknowledged: ["chat": old]))
        let notification = try JSONDecoder().decode(CodexAppServerV2.ThreadSettingsUpdatedNotification.self,
            from: Data(#"{"threadId":"chat","threadSettings":{"model":"gpt-6-astra","effort":"high","serviceTier":null}}"#.utf8))
        await fixture.service.observeSettings(notification, observedAt: Date(timeIntervalSince1970: 150))
        var automatic = old
        automatic.reasoningSelectionID = "automatic"
        automatic.updatedAt = Date(timeIntervalSince1970: 200)
        automatic.serverRevision = 2
        await fixture.remote.configure(entries: ["chat": automatic])
        await fixture.service.sync()
        #expect(await fixture.service.metadata(for: "chat") == automatic)
        #expect(try await fixture.store.load().observed?["chat"] == nil)
    }

    @Test(arguments: ["", ",\"serviceTier\":null", ",\"serviceTier\":\"priority\""])
    func runtimeFastReadbackNeverReplacesTheAcknowledgedRequestedPreference(tierField: String) async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        var preference = record("chat", model: "gpt-6-astra", revision: 1)
        preference.fastModeEnabled = true
        try await fixture.store.save(.init(acknowledged: ["chat": preference]))
        let wire = Data("{\"threadId\":\"chat\",\"threadSettings\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"\(tierField)}}".utf8)
        let notification = try JSONDecoder().decode(CodexAppServerV2.ThreadSettingsUpdatedNotification.self, from: wire)
        await fixture.service.observeSettings(notification, observedAt: Date(timeIntervalSince1970: 150))
        let restored = try #require(await fixture.service.metadata(for: "chat"))
        #expect(restored.fastModeEnabled == true)
        #expect(try await fixture.store.load().observed?["chat"]?.metadata.fastModeEnabled == notification.threadSettings.fastModeSelection)
        #expect(await fixture.remote.readCount == 0)
    }

    @Test func selectingTheOldPreferenceAfterRuntimeChangeCreatesAnExplicitConflict() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        var automatic = record("chat", model: "gpt-6-astra", revision: 1)
        automatic.reasoningSelectionID = "automatic"
        try await fixture.store.save(.init(acknowledged: ["chat": automatic]))
        var high = automatic
        high.reasoningSelectionID = "effort-high"
        high.serverRevision = 2
        await fixture.remote.configure(entries: ["chat": high], holdRead: true)
        let notification = try JSONDecoder().decode(CodexAppServerV2.ThreadSettingsUpdatedNotification.self,
            from: Data(#"{"threadId":"chat","threadSettings":{"model":"gpt-6-astra","effort":"high","serviceTier":"default"}}"#.utf8))
        await fixture.service.observeSettings(notification, observedAt: .now)
        await fixture.service.upsert(sessionID: "chat", modelID: automatic.modelID,
            reasoningSelectionID: "automatic", fastModeEnabled: false, source: .selection)
        let pending = try #require(try await fixture.store.load().pending["chat"])
        #expect(pending.mutation.expectedRevision == 1)
        #expect(await fixture.service.metadata(for: "chat")?.selection == automatic.selection)
        await fixture.remote.releaseRead()
        await fixture.service.sync()
        #expect(try await fixture.store.load().pending["chat"]?.mutation == pending.mutation)
        #expect(await fixture.service.status.conflicts == ["chat"])
        #expect(await fixture.remote.appliedCount == 0)
    }

    @Test func selectingAValidAcknowledgedPreferenceAgainDoesNotCreateWork() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        var automatic = record("chat", model: "gpt-6-astra", revision: 1)
        automatic.reasoningSelectionID = "automatic"
        try await fixture.store.save(.init(acknowledged: ["chat": automatic]))
        await fixture.remote.configure(entries: ["chat": automatic])
        await fixture.service.upsert(sessionID: "chat", modelID: automatic.modelID,
            reasoningSelectionID: "automatic", fastModeEnabled: false, source: .selection)
        #expect(try await fixture.store.load().pending.isEmpty)
        #expect(await fixture.remote.readCount == 0)
        #expect(await fixture.remote.appliedCount == 0)
    }

    @Test func runtimeObservationPreservesPendingMutationIdentityAndPreventsLegacyReplay() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        let old = record("legacy", model: "opus", revision: 0)
        let selection = ConversationMetadataSelection(sessionID: "pending", modelID: "opus",
            reasoningSelectionID: "effort-max", fastModeEnabled: false, source: .selection)
        let pending = SessionMetadataPending(mutation: .init(selection: selection, expectedRevision: 1,
            mutationID: "pending"), createdAt: Date(timeIntervalSince1970: 100))
        try await fixture.store.save(.init(pending: ["pending": pending], legacy: ["legacy": old]))
        await fixture.remote.configure(entries: [:])
        for id in ["pending", "legacy"] {
            let data = Data("{\"threadId\":\"\(id)\",\"threadSettings\":{\"model\":\"opus\",\"effort\":\"high\",\"serviceTier\":null}}".utf8)
            let notification = try JSONDecoder().decode(CodexAppServerV2.ThreadSettingsUpdatedNotification.self, from: data)
            await fixture.service.observeSettings(notification, observedAt: .now)
        }
        #expect(await fixture.service.metadata(for: "pending") == pending.metadata)
        #expect(try await fixture.store.load().pending["pending"] == pending)
        await fixture.service.sync()
        #expect(await fixture.remote.entries["legacy"] == nil)
        #expect(await fixture.service.metadata(for: "legacy")?.reasoningSelectionID == "effort-high")
    }

    @Test func localEditSurvivesAnOlderRemoteReadCompletingAfterIt() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        let old = record("chat", model: "gpt-5.6-sol", revision: 1)
        let remoteOnly = record("remote-only", model: "opus", revision: 1)
        try await fixture.store.save(SessionMetadataLocalState(acknowledged: [old.sessionID: old]))
        await fixture.remote.configure(entries: [old.sessionID: old, remoteOnly.sessionID: remoteOnly], holdRead: true)
        let sync = Task { await fixture.service.sync() }
        await fixture.remote.waitForRead()
        await fixture.service.upsert(sessionID: "chat", modelID: "gpt-6-astra", reasoningSelectionID: "effort-xhigh",
            fastModeEnabled: true, source: .selection)
        await fixture.remote.releaseRead()
        await sync.value
        #expect(await fixture.service.metadata(for: "chat")?.modelID == "gpt-6-astra")
        #expect(try await fixture.store.load().acknowledged["chat"]?.fastModeEnabled == true)
        #expect(await fixture.remote.entries["chat"]?.modelID == "gpt-6-astra")
        #expect(await fixture.service.metadata(for: "remote-only") == remoteOnly)
    }

    @Test func concurrentFirstReadsCannotReplaceAnEditWithTheInitialDiskSnapshot() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = await fixture.service.metadata(for: "chat") } }
            group.addTask {
                await fixture.service.upsert(sessionID: "chat", modelID: "opus", reasoningSelectionID: "effort-max",
                    fastModeEnabled: false, source: .selection)
            }
        }
        await fixture.service.sync()
        #expect(await fixture.service.metadata(for: "chat")?.modelID == "opus")
        #expect(try await fixture.store.load().acknowledged["chat"]?.reasoningSelectionID == "effort-max")
    }

    @Test(arguments: [false, true])
    func reasoningEditRetainsTheSavedFastPreference(savedFast: Bool) async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        let saved = ConversationMetadata(sessionID: "chat", modelID: "gpt-5.6-sol",
            reasoningSelectionID: "effort-high", fastModeEnabled: savedFast,
            source: .selection, updatedAt: .now, serverRevision: 1)
        try await fixture.store.save(SessionMetadataLocalState(acknowledged: ["chat": saved]))
        await fixture.remote.configure(entries: ["chat": saved])
        await fixture.service.upsert(sessionID: "chat", modelID: "gpt-5.6-sol",
            reasoningSelectionID: "effort-medium", fastModeEnabled: nil,
            source: .selection)
        await fixture.service.sync()
        #expect(await fixture.service.metadata(for: "chat")?.fastModeEnabled == savedFast)
        #expect(await fixture.remote.entries["chat"]?.fastModeEnabled == savedFast)
        #expect(await fixture.remote.entries["chat"]?.reasoningSelectionID == "effort-medium")
    }

    @Test func lostAcknowledgementRetriesTheSameMutationWithoutApplyingTwice() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        await fixture.remote.loseNextAcknowledgement()
        await fixture.service.upsert(sessionID: "chat", modelID: "opus", reasoningSelectionID: "effort-high",
            fastModeEnabled: false, source: .selection)
        await fixture.service.sync()
        await fixture.service.sync()
        #expect(await fixture.remote.appliedCount == 1)
        #expect(await fixture.remote.entries["chat"]?.serverRevision == 1)
        #expect(try await fixture.store.load().pending.isEmpty)
    }

    @Test func anotherClientsNewerRevisionRequiresAnExplicitConflictDecision() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        try await fixture.store.save(SessionMetadataLocalState(acknowledged: ["chat": record("chat", model: "old", revision: 1)]))
        await fixture.remote.configure(entries: ["chat": record("chat", model: "other-client", revision: 2)])
        await fixture.service.upsert(sessionID: "chat", modelID: "local", reasoningSelectionID: "effort-high",
            fastModeEnabled: true, source: .selection)
        await fixture.service.sync()
        #expect(await fixture.remote.entries["chat"]?.modelID == "other-client")
        #expect(await fixture.service.status.conflicts == ["chat"])
        #expect(try await fixture.store.load().pending["chat"]?.mutation.selection.modelID == "local")
        await fixture.service.sync()
        #expect(await fixture.remote.appliedCount == 0)
        await fixture.service.resolveConflict(sessionID: "chat", keepLocal: true)
        await fixture.service.sync()
        #expect(await fixture.remote.entries["chat"]?.modelID == "local")
        #expect(await fixture.remote.entries["chat"]?.serverRevision == 3)
        #expect(await fixture.service.status.conflicts.isEmpty)
    }

    @Test func unreadableLocalStateIsPreservedAndNotPushedAsEmpty() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        let original = Data("unreadable local-only preferences".utf8)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try original.write(to: fixture.file)
        await fixture.service.upsert(sessionID: "chat", modelID: "local", reasoningSelectionID: "effort-high",
            fastModeEnabled: false, source: .selection)
        await fixture.service.sync()
        #expect(try Data(contentsOf: fixture.file) == original)
        #expect(await fixture.remote.appliedCount == 0)
        #expect(await fixture.service.status.error != nil)
    }

    @Test func unchangedPendingValueRetriesAnEarlierFailedLocalSave() async throws {
        let fixture = Fixture()
        defer { await fixture.close() }
        _ = await fixture.service.metadata(for: "chat")
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
        await fixture.service.upsert(sessionID: "chat", modelID: "local", reasoningSelectionID: "effort-high",
            fastModeEnabled: false, source: .selection)
        #expect(await fixture.service.status.error != nil)
        #expect(await fixture.remote.appliedCount == 0)
        try FileManager.default.removeItem(at: fixture.file)
        await fixture.service.upsert(sessionID: "chat", modelID: "local", reasoningSelectionID: "effort-high",
            fastModeEnabled: false, source: .selection)
        await fixture.service.sync()
        #expect(await fixture.remote.entries["chat"]?.modelID == "local")
        #expect(try await fixture.store.load().pending.isEmpty)
    }

    private func record(_ id: String, model: String, revision: UInt64) -> ConversationMetadata {
        ConversationMetadata(sessionID: id, modelID: model, reasoningSelectionID: "effort-high", fastModeEnabled: false,
            source: .selection, updatedAt: Date(timeIntervalSince1970: 100), serverRevision: revision)
    }

    private struct Fixture: Sendable {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        let remote = MetadataRemoteFixture()
        let store: ConversationMetadataStore
        let service: ConversationMetadataService
        var directory: URL { temporary.storage.directory(for: .host(hostID)) }
        var file: URL { directory.appending(path: "codex-session-metadata.json") }
        init() {
            store = ConversationMetadataStore(hostID: hostID, storage: temporary.storage)
            service = ConversationMetadataService(remote: remote, store: store)
        }
        func close() async {
            await remote.releaseRead()
            await service.retire()
            temporary.cleanUp()
        }
    }
}

private actor MetadataRemoteFixture: ConversationMetadataRemote {
    private(set) var entries: [String: ConversationMetadata] = [:]
    private(set) var appliedCount = 0
    private(set) var readCount = 0
    private var readsFail = false
    private var loseAcknowledgement = false
    private var isHoldingRead = false
    private var readStarted = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReads: [CheckedContinuation<Void, Never>] = []

    func configure(entries: [String: ConversationMetadata], holdRead: Bool = false) {
        self.entries = entries
        isHoldingRead = holdRead
    }
    func loseNextAcknowledgement() { loseAcknowledgement = true }
    func failReads(_ value: Bool) { readsFail = value }

    func fetchRemoteMetadata() async throws -> [String: ConversationMetadata] {
        readCount += 1
        if readsFail { throw URLError(.networkConnectionLost) }
        let snapshot = entries
        readStarted = true
        let waiters = readWaiters
        readWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if isHoldingRead { await withCheckedContinuation { pendingReads.append($0) } }
        return snapshot
    }

    func updateRemoteMetadata(_ mutation: ConversationMetadataMutation) throws -> ConversationMetadata {
        let current = entries[mutation.selection.sessionID]
        if let current, current.mutationID == mutation.mutationID { return current }
        guard (current?.serverRevision ?? 0) == mutation.expectedRevision else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let current = try current.map { try JSONDecoder().decode(JSONValue.self, from: encoder.encode($0)) } ?? .null
            throw try #require(GatewayRPCFailure(code: -32009, message: "Another client changed these settings",
                data: .object(["kind": .string("metadataConflict"), "retryable": .bool(false), "current": current])))
        }
        var record = mutation.selection.localMetadata(updatedAt: .now)
        record.serverRevision = mutation.expectedRevision + 1
        record.mutationID = mutation.mutationID
        entries[record.sessionID] = record
        appliedCount += 1
        if loseAcknowledgement { loseAcknowledgement = false; throw URLError(.networkConnectionLost) }
        return record
    }

    func waitForRead() async {
        if !readStarted { await withCheckedContinuation { readWaiters.append($0) } }
    }
    func releaseRead() {
        isHoldingRead = false
        let pending = pendingReads
        pendingReads.removeAll()
        pending.forEach { $0.resume() }
    }
}
