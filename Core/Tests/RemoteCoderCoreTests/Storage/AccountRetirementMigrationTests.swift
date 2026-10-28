import Foundation
import SwiftData
import Testing
@testable import RemoteCoderCore

@MainActor
struct AccountRetirementMigrationTests {
    @Test(arguments: ["claude_migrated", "codex-migrated"])
    func retiredEnrollmentDraftsAndHistoryAdoptTheirHost(thread: String) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let account = UUID()
        let conversation = UUID()
        let directory = temporary.storage.directory(for: .account(host: host, account: account))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([thread: conversation]).write(to: directory.appending(path: "session-index.json"))
        let attachment = ComposerAttachment.text("Keep attachment")
        let file = ComposerFileAttachment(id: UUID(), name: "kept.txt", byteCount: 10, placement: .staged(fileName: "kept.txt"))
        let staged = directory.appending(path: "upload-staging/\(file.id)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("kept bytes".utf8).write(to: staged.appending(path: "kept.txt"))
        try saveLegacyDraft(directory: directory.appending(path: "drafts"), thread: thread, attachments: [attachment, .file(file)])
        let root = temporary.storage.directory(for: .host(host))
        let target = ComposerDraftStore(directory: root.appending(path: "drafts"))
        target.setText("Host draft", in: try #require(await target.draft(for: .thread(thread))))
        #expect(await target.flush())
        let header = try ThreadFixture.decode(["id": thread, "preview": "Saved history", "modelProvider": "anthropic",
            "createdAt": 100, "updatedAt": 200, "cwd": "/repo", "cliVersion": "test", "source": "appServer"])
        let finishedChild = try ThreadFixture.decode(["id": "claude_child", "preview": "Spawn prompt", "modelProvider": "anthropic",
            "createdAt": 100, "updatedAt": 300, "cwd": "/repo", "cliVersion": "test", "source": "appServer", "parentThreadId": thread])
        await ConversationHeaderStore(hostID: host, directory: directory.appending(path: "history"))
            .save(snapshot: .init(threads: [finishedChild, header], lastSuccessfulRefreshAt: nil, revision: 1))
        let checkpoints = temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        var checkpoint = ConversationState(conversationID: conversation, threadID: thread).checkpoint
        checkpoint.lastTurnCompletedAt = 123
        try JSONEncoder().encode(["checkpoint": checkpoint]).write(to: checkpoints.appending(path: "\(conversation).json"))

        let voice = RealtimeVoiceHistoryStore(fileURL: directory.appending(path: "realtime-voice-history.json"))
        await voice.append(role: .user, text: "Spoken request", date: Date(timeIntervalSince1970: 200), threadID: thread)
        await voice.flush()

        let hostMarks = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 1, revision: 7, readBaseline: 100,
            threads: ["codex_chat": ThreadMarks(pinName: "Codex pin")]))
        try JSONEncoder().encode(hostMarks).write(to: root.appending(path: "conversation-marks.json"))
        var oldMarks = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 1, revision: 2, readBaseline: 200,
            threads: [thread: ThreadMarks(pinName: "Claude pin")]))
        oldMarks.record(.markAllRead(through: 300))
        oldMarks.record(.pin(threadID: thread, name: "Pending Claude pin"))
        try JSONEncoder().encode(oldMarks).write(to: directory.appending(path: "conversation-marks.json"))

        let pagesURL = temporary.storage.root.appending(path: "history-pages")
        let oldKey = HistoryPageKey(hostID: "ws://mini.test:8766/ws?accountId=\(account.uuidString)&accountGeneration=2",
                                    provider: "native", threadID: thread, generation: 0, request: "tail")
        try await HistoryPageCache(directory: pagesURL).store(Data("cached history".utf8), for: oldKey, startedAt: .now, readStartedAt: .now)

        let outcome = await run(temporary, hosts: [host])
        #expect(outcome.migrated == [host: [account]])
        #expect(outcome.issues.isEmpty)
        let reopened = ComposerDraftStore(directory: root.appending(path: "drafts"))
        let expected = ComposerDocumentContent(runs: [.text("Host draft\n\nEnrollment draft"),
            .paste(.init(id: attachment.id, text: "Keep attachment"))])
        let migrated = try #require(await reopened.draft(for: .thread(thread)))
        #expect(migrated.documentContent == expected)
        #expect(migrated.text == expected.expandedText)
        #expect(migrated.attachments == [.file(file)])
        let uploaded = try #require(UploadStaging(directory: root.appending(path: "upload-staging")).url(for: file))
        #expect(try Data(contentsOf: uploaded) == Data("kept bytes".utf8))
        #expect(await RealtimeVoiceHistoryStore(hostID: host, storage: temporary.storage).entries(for: thread).map(\.text) == ["Spoken request"])
        guard case .stored(let marks) = await ConversationMarksStore(directory: root).load() else {
            Issue.record("Migrated marks must remain readable")
            return
        }
        #expect(!marks.isReadStateKnown)
        #expect(marks.effective.pinNames["codex_chat"] == "Codex pin")
        #expect(marks.effective.pinNames[thread] == "Pending Claude pin")
        let hostKey = HistoryPageKey(hostID: "ws://mini.test:8766/ws", provider: "native", threadID: thread, generation: 0, request: "tail")
        #expect(await HistoryPageCache(directory: pagesURL).value(for: hostKey)?.data == Data("cached history".utf8))
        #expect(ConversationIndex.legacyEntriesSynchronously(directory: root)[thread] == conversation)
        #expect(Set(await ConversationHeaderStore(hostID: host, storage: temporary.storage).load().threads.map(\.id)) == [thread])
        let migratedCheckpoint = try await ConversationCheckpointStore(hostID: host, storage: temporary.storage,
            primaryBudgetBytes: 512 * 1_024 * 1_024).load(conversation, threadID: thread)
        #expect(migratedCheckpoint?.lastTurnCompletedAt == 123)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: checkpoints.path))
        #expect(marks.pending.contains { $0.change == .markRetiredScopeRead(scopeID: account.uuidString.lowercased(), through: 300) })
        #expect(marks.effective.threads["codex_chat"]?.seenThrough == nil)
        _ = await run(temporary, hosts: [host])
        #expect(await ComposerDraftStore(directory: root.appending(path: "drafts")).draft(for: .thread(thread))?.documentContent == expected)
    }

    @Test func aResumedPassLeavesAdmittedHostFilesAndTheSharedPageCacheAlone() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let admitted = UUID(), account = UUID(), pending = UUID(), otherAccount = UUID()
        let folder = temporary.storage.directory(for: .account(host: admitted, account: account))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceIndex = folder.appending(path: "session-index.json")
        try JSONEncoder().encode(["old": UUID()]).write(to: sourceIndex)
        let other = temporary.storage.directory(for: .account(host: pending, account: otherAccount))
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let pages = temporary.storage.root.appending(path: "history-pages")
        let oldKey = HistoryPageKey(hostID: "ws://mini.test:8766/ws?accountId=\(account)",
            provider: "native", threadID: "old", generation: 0, request: "tail")
        try await HistoryPageCache(directory: pages).store(Data("owned cache".utf8), for: oldKey, startedAt: .now, readStartedAt: .now)
        let before = try FileManager.default.contentsOfDirectory(atPath: pages.path)
        var discovered: Set<UUID> = [], finished: [UUID] = []
        let outcome = await AccountRetirementMigration.Ledger(defaults: try isolatedDefaults()).run(
            hosts: [admitted, pending], excluding: [admitted], storage: temporary.storage,
            discovered: { discovered = $0 }, finishedHost: { finished.append($0) })
        #expect(discovered == [pending])
        #expect(finished == [pending])
        #expect(outcome.migrated == [pending: [otherAccount]])
        #expect(FileManager.default.fileExists(atPath: sourceIndex.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: pages.path) == before)
        #expect(!FileManager.default.fileExists(atPath: temporary.storage.directory(for: .host(admitted))
            .appending(path: "retired-accounts/default.json").path))
    }

    @Test func importingIdenticalLegacyDraftsRetainsThePasteOnce() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let source = temporary.storage.root.appending(path: "source-drafts")
        let target = temporary.storage.root.appending(path: "target-drafts")
        let thread = "claude_identical"
        let attachment = ComposerAttachment.text("Keep attachment")
        try saveLegacyDraft(directory: source, thread: thread, attachments: [attachment])
        try saveLegacyDraft(directory: target, thread: thread, attachments: [attachment])

        try ComposerDraftStore.importDrafts(from: source, into: target, conversationIDs: [:], scope: .retiredAccount(hostID: UUID(), accountID: UUID()))
        try ComposerDraftStore.importDrafts(from: source, into: target, conversationIDs: [:], scope: .retiredAccount(hostID: UUID(), accountID: UUID()))

        let reopened = ComposerDraftStore(directory: target)
        let draft = try #require(await reopened.draft(for: .thread(thread)))
        let expected = ComposerDocumentContent(runs: [.text("Enrollment draft"),
            .paste(.init(id: attachment.id, text: "Keep attachment"))])
        #expect(draft.documentContent == expected)
        #expect(draft.text == expected.expandedText)
        #expect(draft.attachments.isEmpty)
    }

    @Test func discoveryWithoutLoadedHostsFindsBothStorageRootsAndLegacyKeys() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), orphan = UUID(), pinned = UUID(), conversation = UUID()
        let defaults = try isolatedDefaults()
        let ledger = AccountRetirementMigration.Ledger(defaults: defaults)
        #expect(try await ledger.plan(hosts: [], storage: temporary.storage).candidates.isEmpty)
        let folder = temporary.storage.directory(for: .account(host: host, account: account))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(["indexed": conversation]).write(to: folder.appending(path: "session-index.json"))
        let orphanFolder = temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(orphan)")
        try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
        let key = "codex.pinnedSessionNames.\(host).account.\(pinned)"
        let hostMarks = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 7, readBaseline: 100, threads: [:]))
        try JSONEncoder().encode(hostMarks).write(to: temporary.storage.directory(for: .host(host)).appending(path: ConversationMarksStore.fileName))
        let hostPinsKey = "codex.pinnedSessionNames.\(host)"
        defaults.set(["default-old": "Host pin"], forKey: hostPinsKey)
        defaults.set(["unsynced": "Keep", "default-old": "Source pin"], forKey: key)
        #expect(try await ledger.plan(hosts: [], storage: temporary.storage).candidates == [host: [account, orphan, pinned]])
        #expect(try await ledger.plan(hosts: [host], storage: temporary.storage).candidates == [host: [account, orphan, pinned]])
        let outcome = await ledger.run(hosts: [], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        #expect(outcome.issues.isEmpty)
        #expect(outcome.migrated[host] == [account, orphan, pinned])
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.object(forKey: hostPinsKey) == nil)
        #expect(try await ledger.plan(hosts: [host], storage: temporary.storage).candidates == [host: []])
        let marks = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf:
            temporary.storage.directory(for: .host(host)).appending(path: ConversationMarksStore.fileName)))
        #expect(marks.pending.contains { $0.change == .pin(threadID: "unsynced", name: "Keep") })
        #expect(!marks.isReadStateKnown)
        #expect(marks.effective.pinNames["default-old"] == "Host pin")
    }

    @Test func unindexedSubmissionsAndRestoredDraftsKeepTheirIdentity() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), conversation = UUID(), slot = UUID(), draftID = UUID()
        let folder = temporary.storage.directory(for: .account(host: host, account: account))
        let setup = NewChatSetup(workingDirectory: "/saved/repo", modelID: "gpt-6-sol", reasoning: .effort(.high), fastMode: true)
        let recording = UUID()
        do {
            let context = try ComposerDraftStore.makeContext(directory: folder.appending(path: "drafts"))
            let draft = ComposerDraft(destination: ComposerDraftStore.Destination.newChat(slot).key)
            draft.id = draftID
            draft.text = "Unsent draft"
            draft.newChat = setup
            draft.modifiedAt = Date(timeIntervalSince1970: 100)
            context.insert(draft)
            context.insert(DictationReceipt(recordingID: recording, receivedAt: .now))
            try context.save()
        }
        let checkpoints = temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")
        let source = ConversationCheckpointStore(hostID: host, directory: checkpoints, storage: temporary.storage,
            primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: conversation)
        let message = ChatMessage(role: .user, text: "Interrupted before thread creation")
        state.submit(message)
        let submission = try #require(state.submissions[message.id])
        try await source.saveSubmission(.init(revision: state.persistenceRevision, threadID: nil, submission: submission),
            conversationID: conversation, generation: await source.generation(for: conversation))
        _ = await run(temporary, hosts: [host])
        let destination = temporary.storage.directory(for: .host(host))
        let drafts = ComposerDraftStore(directory: destination.appending(path: "drafts"))
        let restored = try #require(await drafts.draft(for: .newChat(AccountRetirementMigration.draftSlot(hostID: host, accountID: account, slot: slot))))
        #expect(restored.id == draftID)
        #expect(restored.newChat == setup)
        #expect(restored.text == "Unsent draft")
        #expect(try await drafts.hasSavedReceipt(for: recording))
        let checkpoint = try await ConversationCheckpointStore(hostID: host, storage: temporary.storage,
            primaryBudgetBytes: 512 * 1_024 * 1_024).load(conversation)
        #expect(checkpoint?.submissions[message.id]?.input == "Interrupted before thread creation")
        #expect(checkpoint?.submissions[message.id]?.status == .uncertain)
        #expect(await drafts.retire())
    }

    @Test func aCheckpointDoesNotRequireAnAccountIndexOrDraftDirectory() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), conversation = UUID()
        let directory = temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")
        let source = ConversationCheckpointStore(hostID: host, directory: directory, storage: temporary.storage,
            primaryBudgetBytes: 512 * 1_024 * 1_024)
        var checkpoint = ConversationState(conversationID: conversation, threadID: "codex-orphan").checkpoint
        checkpoint.lastTurnCompletedAt = 321
        try await source.save(checkpoint, conversationID: conversation)
        let ledger = AccountRetirementMigration.Ledger(defaults: try isolatedDefaults())
        _ = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        let restored = try await ConversationCheckpointStore(hostID: host, storage: temporary.storage,
            primaryBudgetBytes: 512 * 1_024 * 1_024).load(conversation, threadID: "codex-orphan")
        #expect(restored?.lastTurnCompletedAt == 321)
        #expect(ConversationIndex.legacyEntriesSynchronously(directory: temporary.storage.directory(for: .host(host)))["codex-orphan"] == conversation)
        #expect(try await ledger.plan(hosts: [host], storage: temporary.storage).candidates == [host: []])
    }

    @Test func pendingCodexResetsKeepTheirReceiptWhenTheEndpointRetires() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = "AAAAAAAA-0000-0000-0000-000000000001"
        let key = "bbbbbbbb-0000-0000-0000-000000000002"
        let json = Data("""
            {"codex:main":{"resetId":"old-offer","title":"Extra usage","idempotencyKey":"\(key)",
            "hostID":"\(host)","gatewayAccountID":"cccccccc-0000-0000-0000-000000000003","accountName":"Main"}}
            """.utf8)
        try FileManager.default.createDirectory(at: temporary.storage.root, withIntermediateDirectories: true)
        let path = temporary.storage.root.appending(path: "codex-reset-attempts-v1.json")
        try json.write(to: path)
        let pending = try await ResetRedemptionStore(storage: temporary.storage, provider: .codex).load()
        let attempt = try #require(pending["codex:main"])
        #expect(attempt.gatewayAccountID == "default-codex")
        #expect(attempt.canonicalIdempotencyKey == key)
        #expect(attempt.resetId == "old-offer")
        #expect(attempt.hostID.uuidString == host)
        let saved = try JSONDecoder().decode([String: ResetRedemptionAttempt].self, from: Data(contentsOf: path))
        #expect(saved == pending)
    }

    @Test func aHistoryPageDoesNotRequireAnEnrollmentDirectoryToMigrate() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let pages = temporary.storage.root.appending(path: "history-pages")
        let old = HistoryPageKey(hostID: "ws://mini.test/ws?accountId=AAAAAAAA-0000-0000-0000-000000000001&accountGeneration=8",
            provider: "native", threadID: "codex-cached", generation: 0, request: "tail")
        try await HistoryPageCache(directory: pages).store(Data("Retained page".utf8), for: old, startedAt: .now, readStartedAt: .now)
        let host = UUID()
        let ledger = AccountRetirementMigration.Ledger(defaults: try isolatedDefaults())
        _ = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        let key = HistoryPageKey(hostID: "ws://mini.test/ws", provider: "native", threadID: "codex-cached", generation: 0, request: "tail")
        #expect(await HistoryPageCache(directory: pages).value(for: key)?.data == Data("Retained page".utf8))
        #expect(try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil).filter { $0.pathExtension == "plist" }.count == 1)
        #expect(try await ledger.plan(hosts: [host], storage: temporary.storage).candidates == [host: []])
    }

    @Test func collidingNewChatDraftsAndRestoredWindowReferencesKeepBothSetups() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), slot = UUID()
        let source = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        let setupA = NewChatSetup(workingDirectory: "/repo/A", modelID: "gpt-6-sol", reasoning: .effort(.medium), fastMode: false)
        let setupB = NewChatSetup(workingDirectory: "/repo/B", modelID: "gpt-6-astra", reasoning: .effort(.xhigh), fastMode: true)
        for (folder, setup, text) in [(target, setupA, "Draft A"), (source, setupB, "Draft B")] {
            let context = try ComposerDraftStore.makeContext(directory: folder.appending(path: "drafts"))
            let draft = ComposerDraft(destination: ComposerDraftStore.Destination.newChat(slot).key)
            draft.newChat = setup
            draft.text = text
            context.insert(draft)
            try context.save()
        }
        let restored = try JSONDecoder().decode(UnsentDraftAddress.self, from: Data("""
            {"target":{"hostID":"\(host)","accountID":"\(account)"},"draftID":"\(slot)"}
            """.utf8))
        let outcome = await run(temporary, hosts: [host])
        #expect(outcome.issues.isEmpty)
        let drafts = ComposerDraftStore(directory: target.appending(path: "drafts"))
        let a = try #require(await drafts.draft(for: .newChat(slot)))
        let b = try #require(await drafts.draft(for: .newChat(restored.draftID)))
        #expect(restored.target == ExecutionTarget(hostID: host))
        #expect(restored.draftID != slot)
        #expect(a.text == "Draft A" && a.newChat == setupA)
        #expect(b.text == "Draft B" && b.newChat == setupB)
        #expect(a.id != b.id)
        _ = await run(temporary, hosts: [host])
        #expect(try ComposerDraftStore.makeContext(directory: target.appending(path: "drafts")).fetch(FetchDescriptor<ComposerDraft>()).count == 2)
    }

    @Test(arguments: [0, 3])
    func currentMetadataImportsWithFreshOrPreviouslyExhaustedAttempts(attempts: Int) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID()
        let source = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceData = Data("""
            {"version":3,"acknowledged":{"retired":{"sessionID":"retired","modelID":"gpt-6-sol",
            "reasoningSelectionID":"effort-xhigh","fastModeEnabled":true,"source":"selection",
            "updatedAt":813185475.509233,"serverRevision":1,"mutationId":"retired-selection"}},
            "pending":{},"invalidated":["retired"],"observed":{"observed":{"metadata":{
            "sessionID":"observed","modelID":"gpt-6-sol","reasoningSelectionID":"effort-high",
            "source":"runtime","updatedAt":813185475.509233},"acknowledgedRevision":2}}}
            """.utf8)
        try sourceData.write(to: source.appending(path: "codex-session-metadata.json"))
        let retained = ConversationMetadata(sessionID: "host", modelID: "gpt-6-astra", reasoningSelectionID: "automatic",
            updatedAt: Date(timeIntervalSinceReferenceDate: 813185475.125), serverRevision: 3)
        let store = ConversationMetadataStore(hostID: host, storage: temporary.storage)
        try await store.save(.init(acknowledged: ["host": retained], invalidated: ["host"]))
        let journal = target.appending(path: "retired-accounts/\(account).json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"attempts":\(attempts),"completed":false,"conversations":[],"failure":"Previous format error"}
            """.utf8).write(to: journal)

        let outcome = await run(temporary, hosts: [host])

        #expect(outcome.issues.isEmpty)
        #expect(outcome.migrated == [host: [account]])
        let restored = try await store.load()
        let imported = try #require(restored.acknowledged["retired"])
        #expect(imported.updatedAt == Date(timeIntervalSinceReferenceDate: 813185475.509233))
        #expect(imported.modelID == "gpt-6-sol")
        #expect(imported.mutationID == "retired-selection")
        #expect(restored.acknowledged["host"] == retained)
        #expect(restored.invalidated == ["host", "retired"])
        #expect(restored.observed?["observed"]?.metadata.updatedAt == imported.updatedAt)
        #expect(restored.observed?["observed"]?.acknowledgedRevision == 2)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let progress = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        #expect(progress["completed"] as? Bool == true)
        #expect(progress["attempts"] as? Int == 1)
    }

    @Test func checkpointCollisionsKeepAllIndexAliasesAndRetriesDoNotReviveDiscardedWork() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), oldID = UUID(), hostID = UUID(), aliasID = UUID()
        let folder = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try JSONEncoder().encode(["shared": oldID, "alias": oldID, "collision": oldID]).write(to: folder.appending(path: "session-index.json"))
        try JSONEncoder().encode(["shared": hostID, "collision": aliasID]).write(to: target.appending(path: "session-index.json"))
        let source = ConversationCheckpointStore(hostID: host, directory: temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)"), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var incoming = ConversationState(conversationID: oldID, threadID: "shared")
        let imported = ChatMessage(role: .user, text: "Enrollment work")
        incoming.submit(imported)
        try await source.save(incoming.checkpoint, conversationID: oldID)
        let destination = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var existing = ConversationState(conversationID: hostID, threadID: "shared")
        let original = ChatMessage(role: .user, text: "Host work")
        existing.submit(original)
        try await destination.save(existing.checkpoint, conversationID: hostID)
        try Data("broken metadata".utf8).write(to: folder.appending(path: "codex-session-metadata.json"))
        let sourceMarks = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 200, threads: [:]))
        try JSONEncoder().encode(sourceMarks).write(to: folder.appending(path: ConversationMarksStore.fileName))
        let ledger = AccountRetirementMigration.Ledger(defaults: try isolatedDefaults())
        var released: [UUID] = []
        let first = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { released.append($0) })
        #expect(!first.issues.isEmpty)
        #expect(released == [host])
        let merged = try #require(try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(hostID))
        #expect(Set(merged.submissions.keys) == [original.id, imported.id])
        let index = ConversationIndex.legacyEntriesSynchronously(directory: target)
        #expect(index == ["shared": hostID, "alias": hostID, "collision": aliasID])
        let path = temporary.storage.root.appending(path: "conversations-v1/\(host)/\(hostID).sqlite")
        let before = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let marksPath = target.appending(path: ConversationMarksStore.fileName)
        var hostMarks = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: marksPath))
        hostMarks.record(.markUnread(threadID: "shared"))
        try JSONEncoder().encode(hostMarks).write(to: marksPath)
        for _ in 0..<3 {
            let retry = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
            #expect(!retry.issues.isEmpty)
        }
        let after = try #require(try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(hostID))
        #expect(after.durableRevision == merged.durableRevision)
        let retriedMarks = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: marksPath))
        #expect(retriedMarks == hostMarks)
        #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let journal = target.appending(path: "retired-accounts/\(account).json")
        let progress = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        #expect(progress["attempts"] as? Int == 3)
        var edited = ConversationState(conversationID: hostID, threadID: "shared")
        edited.restore(after)
        edited.submissionNotDispatched(imported.id)
        try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
            .save(edited.checkpoint, conversationID: hostID)
        _ = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        let reopened = try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(hostID)
        #expect(reopened?.submissions[imported.id] == nil)
    }

    @Test(arguments: [false, true])
    func completedClaudeImportsDoNotRestoreDiscardedSubmissions(useLedger: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), conversation = UUID()
        let folder = temporary.storage.directory(for: .account(host: host, account: account))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = try isolatedDefaults()
        if useLedger {
            defaults.set([host.uuidString: [account.uuidString]], forKey: "accounts.claude-host-migration.completed.v1")
        } else { try Data().write(to: folder.appending(path: "claude-host-migrated-v1")) }
        let source = ConversationCheckpointStore(hostID: host, directory: temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)"), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var old = ConversationState(conversationID: conversation, threadID: "claude_old")
        old.submit(ChatMessage(role: .user, text: "Discarded after the first migration"))
        try await source.save(old.checkpoint, conversationID: conversation)
        let destination = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await destination.save(ConversationState(conversationID: conversation, threadID: "claude_old").checkpoint, conversationID: conversation)
        let outcome = await AccountRetirementMigration.Ledger(defaults: defaults).run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        #expect(outcome.issues.isEmpty)
        let restored = try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(conversation)
        #expect(restored?.submissions.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func anInterruptedUnindexedCheckpointRetainsItsPendingScopedRead() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), conversation = UUID()
        let folder = temporary.storage.directory(for: .account(host: host, account: account))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marksURL = folder.appending(path: ConversationMarksStore.fileName)
        try Data("corrupt marks".utf8).write(to: marksURL)
        let checkpoints = temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")
        let source = ConversationCheckpointStore(hostID: host, directory: checkpoints, storage: temporary.storage,
                                               primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await source.save(ConversationState(conversationID: conversation, threadID: "orphan").checkpoint, conversationID: conversation)
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let hostMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 100, threads: [:]))
        try JSONEncoder().encode(hostMarks).write(to: target.appending(path: ConversationMarksStore.fileName))
        let ledger = AccountRetirementMigration.Ledger(defaults: try isolatedDefaults())
        let first = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        #expect(!first.issues.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: checkpoints.appending(path: "\(conversation).sqlite").path))
        var sourceMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 2, readBaseline: 200, threads: [:]))
        sourceMarks.record(.markAllRead(through: 300))
        try JSONEncoder().encode(sourceMarks).write(to: marksURL)
        let retry = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        #expect(retry.issues.isEmpty)
        let restored = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: target.appending(path: ConversationMarksStore.fileName)))
        #expect(!restored.isReadStateKnown)
        #expect(restored.pending.map(\.id) == sourceMarks.pending.map(\.id))
        #expect(restored.pending.first?.change == .markRetiredScopeRead(scopeID: account.uuidString.lowercased(), through: 300))
    }

    @Test(arguments: [false, true])
    func protectedCheckpointRecoverySurvivesRetirement(alreadyQuarantined: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID(), conversation = UUID()
        let directory = temporary.storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")
        let file = alreadyQuarantined ? directory.appending(path: "recovery/\(conversation)/original.json")
            : directory.appending(path: "\(conversation).json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("unreadable original checkpoint".utf8)
        try bytes.write(to: file)
        let ledger = AccountRetirementMigration.Ledger(defaults: try isolatedDefaults())
        for _ in 0..<4 {
            let outcome = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
            #expect(!outcome.issues.isEmpty)
            #expect(outcome.migrated.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        #expect(files.contains { (try? Data(contentsOf: $0)) == bytes })
    }

    @Test(arguments: [false, true])
    func legacyPinsPrecedePendingUnpinAndSettlement(settled: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID()
        let defaults = try isolatedDefaults()
        let folder = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var marks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 100,
            threads: ["edited": ThreadMarks(pinName: "Old pin")]))
        marks.record(settled ? .settle(threadID: "edited", through: 200) : .unpin(threadID: "edited"))
        try JSONEncoder().encode(marks).write(to: target.appending(path: ConversationMarksStore.fileName))
        defaults.set(["edited": "Old pin", "unsynced": "Retain"], forKey: "codex.pinnedSessionNames.\(host)")
        let outcome = await AccountRetirementMigration.Ledger(defaults: defaults).run(hosts: [host], excluding: [], storage: temporary.storage,
            discovered: { _ in }, finishedHost: { _ in })
        #expect(outcome.issues.isEmpty)
        let restored = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: target.appending(path: ConversationMarksStore.fileName)))
        #expect(restored.effective.pinNames["edited"] == nil)
        #expect(restored.effective.pinNames["unsynced"] == "Retain")
        #expect(restored.pending.last?.change == marks.pending.last?.change)
    }

    @Test(arguments: [false, true])
    func aHigherHostBaselineDoesNotReadTheRetiredThreads(hasPendingGlobalRead: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID()
        let source = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try JSONEncoder().encode(["retired": UUID()]).write(to: source.appending(path: "session-index.json"))
        try JSONEncoder().encode(["host": UUID()]).write(to: target.appending(path: "session-index.json"))
        let hostMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 9, readBaseline: 300, threads: [:]))
        var retiredMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 4, readBaseline: 100, threads: [:]))
        if hasPendingGlobalRead { retiredMarks.record(.markAllRead(through: 250)) }
        try JSONEncoder().encode(hostMarks).write(to: target.appending(path: ConversationMarksStore.fileName))
        try JSONEncoder().encode(retiredMarks).write(to: source.appending(path: ConversationMarksStore.fileName))
        let outcome = await run(temporary, hosts: [host])
        #expect(outcome.issues.isEmpty)
        var restored = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: target.appending(path: ConversationMarksStore.fileName)))
        #expect(!restored.isReadStateKnown)
        #expect(restored.effective.readBaseline == .max)
        restored.receive(.init(schemaVersion: 2, revision: 10, readBaseline: 300, threads: [:]))
        #expect(!restored.isReadStateKnown)
        restored.replaceAcknowledged(.init(schemaVersion: 2, revision: 11, readBaseline: 100,
            threads: ["host": ThreadMarks(revision: 11, seenThrough: 300)], supportsRetiredScopeRead: true))
        #expect(restored.isReadStateKnown)
        let retiredThread = try ThreadFixture.decode(["id": "retired", "preview": "Retired", "modelProvider": "openai",
            "createdAt": 1, "updatedAt": 275, "lastTurnCompletedAt": 275, "cwd": "/repo", "cliVersion": "test", "source": "appServer"])
        let hostThread = try ThreadFixture.decode(["id": "host", "preview": "Host", "modelProvider": "openai",
            "createdAt": 1, "updatedAt": 275, "lastTurnCompletedAt": 275, "cwd": "/repo", "cliVersion": "test", "source": "appServer"])
        #expect(restored.effective.isUnread(retiredThread))
        #expect(restored.effective.isUnseenQuestion(askedAtMs: 275_000, in: "retired"))
        #expect(!restored.effective.isUnread(hostThread))
        #expect(!restored.effective.isUnseenQuestion(askedAtMs: 275_000, in: "host"))
    }

    @Test(arguments: [false, true])
    func aLargeIndexedHistoryDoesNotPreventDraftImport(hasPendingGlobalRead: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID()
        let source = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let entries = try Dictionary(uniqueKeysWithValues: (0..<2_501).map { index in
            ("retired-\(index)", try #require(UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))")))
        })
        try JSONEncoder().encode(entries).write(to: source.appending(path: "session-index.json"))
        try saveLegacyDraft(directory: source.appending(path: "drafts"), thread: "retired-2500", attachments: [])
        let hostMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 100, threads: [:]))
        var retiredMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 200, threads: [:]))
        if hasPendingGlobalRead { retiredMarks.record(.markAllRead(through: 300)) }
        try JSONEncoder().encode(hostMarks).write(to: target.appending(path: ConversationMarksStore.fileName))
        try JSONEncoder().encode(retiredMarks).write(to: source.appending(path: ConversationMarksStore.fileName))
        let outcome = await run(temporary, hosts: [host])
        #expect(outcome.issues.isEmpty)
        #expect(outcome.migrated == [host: [account]])
        var restored = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: target.appending(path: ConversationMarksStore.fileName)))
        #expect(!restored.isReadStateKnown)
        #expect(restored.pending.count == (hasPendingGlobalRead ? 1 : 0))
        restored.replaceAcknowledged(.init(schemaVersion: 2, revision: 1, readBaseline: 100,
            threads: Dictionary(uniqueKeysWithValues: entries.keys.map { ($0, ThreadMarks(revision: 1, seenThrough: 200)) }),
            supportsRetiredScopeRead: true))
        if hasPendingGlobalRead {
            restored.acknowledge(restored.pending, delta: .init(schemaVersion: 2, revision: 2, readBaseline: 100,
                threads: ["retired-2500": ThreadMarks(revision: 2, seenThrough: 300)]))
        }
        let last = try ThreadFixture.decode(["id": "retired-2500", "preview": "Last", "modelProvider": "openai",
            "createdAt": 1, "updatedAt": 250, "lastTurnCompletedAt": 250, "cwd": "/repo", "cliVersion": "test", "source": "appServer"])
        #expect(restored.effective.isUnread(last) == !hasPendingGlobalRead)
        #expect(await ComposerDraftStore(directory: target.appending(path: "drafts")).draft(for: .thread("retired-2500"))?.text == "Enrollment draft")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func theDefaultPendingGlobalReadIsRetiredEvenWithoutAnAccountFolder() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let directory = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: ConversationMarksStore.fileName)
        var old = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 9, readBaseline: 300, threads: [:]))
        old.record(.markAllRead(through: 350))
        let id = try #require(old.pending.first?.id)
        try JSONEncoder().encode(old).write(to: file)
        let defaults = try isolatedDefaults()
        let key = "codex.pinnedSessionNames.\(host)"
        defaults.set(["legacy-only": "Keep"], forKey: key)
        let ledger = AccountRetirementMigration.Ledger(defaults: defaults)
        let first = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        #expect(first.issues.isEmpty)
        var stored = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: file))
        #expect(!stored.isReadStateKnown)
        #expect(stored.pending.last == .init(id: id, change: .markRetiredScopeRead(scopeID: "default", through: 350)))
        #expect(stored.effective.pinName(for: "legacy-only") == "Keep")
        #expect(defaults.object(forKey: key) == nil)
        stored.record(.markAllRead(through: 400))
        try JSONEncoder().encode(stored).write(to: file)
        _ = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        let retried = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: file))
        #expect(retried == stored)
    }

    @Test func tooManyRealPendingEditsRetainTheSourceWithoutEviction() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), account = UUID()
        let source = temporary.storage.directory(for: .account(host: host, account: account))
        let target = temporary.storage.directory(for: .host(host))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let pending = (0..<ConversationMarksReplica.pendingLimit).map { index in
            ConversationMarksReplica.Pending(id: UUID(), change: .markUnread(threadID: "host-\(index)"))
        }
        let hostMarks = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 100, threads: [:]), pending: pending)
        var sourceMarks = ConversationMarksReplica()
        sourceMarks.record(.markAllRead(through: 300))
        try JSONEncoder().encode(hostMarks).write(to: target.appending(path: ConversationMarksStore.fileName))
        let file = source.appending(path: ConversationMarksStore.fileName)
        let bytes = try JSONEncoder().encode(sourceMarks)
        try bytes.write(to: file)
        let ledger = AccountRetirementMigration.Ledger(defaults: try isolatedDefaults())
        let outcome = await ledger.run(hosts: [host], excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
        #expect(!outcome.issues.isEmpty)
        #expect(outcome.migrated.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        let retained = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: target.appending(path: ConversationMarksStore.fileName)))
        #expect(retained.pending == pending)
    }

    private func run(_ temporary: TemporaryHostStorage, hosts: [UUID]) async -> AccountRetirementMigration.Outcome {
        guard let defaults = UserDefaults(suiteName: "Retirement.\(UUID())") else { preconditionFailure("Missing defaults") }
        return await AccountRetirementMigration.Ledger(defaults: defaults).run(hosts: hosts, excluding: [], storage: temporary.storage, discovered: { _ in }, finishedHost: { _ in })
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AccountRetirement.\(UUID())"))
    }

    private func saveLegacyDraft(directory: URL, thread: String, attachments: [ComposerAttachment]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appending(path: "drafts.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: ComposerDraft.self, DictationReceipt.self, configurations: configuration)
        let context = ModelContext(container)
        let draft = ComposerDraft(destination: ComposerDraftStore.Destination.thread(thread).key)
        draft.text = "Enrollment draft"
        draft.attachments = attachments
        context.insert(draft)
        try context.save()
    }
}
