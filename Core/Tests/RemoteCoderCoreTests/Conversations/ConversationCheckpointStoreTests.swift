import Foundation
import SQLite3
import Testing
@testable import RemoteCoderCore

struct ConversationCheckpointStoreTests: ConversationHistoryFixtures {
    enum ImageChange: CaseIterable { case bytes, format, dimensions }

    @Test(arguments: [false, true])
    func overBudgetSavesDoNotRereadExhaustedHistoryUntilItsSourceChanges(cold: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let metrics = PersistenceMetrics()
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1,
            primaryBudgetBytes: 512 * 1_024 * 1_024, metrics: metrics)
        var preserved: [ConversationState] = []
        for index in 0..<4 {
            var state = ConversationState(conversationID: UUID(), threadID: "preserved-\(index)")
            state.submit(ChatMessage(role: .user, text: String(repeating: "Durable local \(index). ", count: 2_048)))
            state.merge(history(items: [.agentMessage(id: "answer", text: String(repeating: "Remote history \(index). ", count: 2_048))],
                threadID: "preserved-\(index)"))
            try await writer.save(state.checkpoint, conversationID: state.conversationID)
            preserved.append(state)
        }
        var active = ConversationState(conversationID: UUID(), threadID: "active")
        active.merge(history(items: [.agentMessage(id: "active-answer", text: "Still working")], threadID: "active"))
        try await writer.save(active.checkpoint, conversationID: active.conversationID)
        let store = cold ? ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1,
            primaryBudgetBytes: 512 * 1_024 * 1_024, metrics: metrics) : writer
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        let firstReads = metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count ?? 0
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        let secondReads = metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count ?? 0
        #expect(secondReads == firstReads, "History inspections \(firstReads) → \(secondReads)")

        let first = try #require(preserved.first)
        #expect(try await store.load(first.conversationID)?.containsLocalRecords == true)
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        let reloadedReads = metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count ?? 0
        #expect(reloadedReads == secondReads + 1)

        var renewed = first
        renewed.markPersistedChange()
        try await store.save(renewed.checkpoint, conversationID: renewed.conversationID)
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        let rewrittenReads = metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count ?? 0
        #expect(rewrittenReads == reloadedReads + 1)
        for state in preserved {
            let saved = try #require(try await store.load(state.conversationID))
            #expect(saved.submissions.mapValues(\.message) == state.checkpoint.submissions.mapValues(\.message))
            #expect(saved.turns.values.allSatisfy { $0.items["answer"] == nil })
        }
    }

    @Test func overBudgetSavesDoNotReinspectCheckpointsProtectedOnlyByRecoveryBytes() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        var remote = ConversationState(conversationID: UUID(), threadID: "remote")
        remote.merge(history(items: [.agentMessage(id: "answer", text: "Rebuildable remote history")], threadID: "remote"))
        #expect(!remote.checkpoint.containsLocalRecords)
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await writer.save(remote.checkpoint, conversationID: remote.conversationID)
        let recovery = directory.appending(path: "recovery/\(remote.conversationID)/incident/original")
        try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        let durable = Data("Unique recovery bytes".utf8)
        try durable.write(to: recovery)
        let metrics = PersistenceMetrics()
        let store = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1,
            primaryBudgetBytes: 512 * 1_024 * 1_024, metrics: metrics)
        var active = ConversationState(conversationID: UUID(), threadID: "active")
        active.merge(history(items: [.agentMessage(id: "active-answer", text: "Still working")], threadID: "active"))
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        let firstReads = metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count
        #expect(firstReads == 1)
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        #expect(metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count == firstReads)
        #expect(try Data(contentsOf: recovery) == durable)
        let retained = try #require(try await store.load(remote.conversationID))
        #expect(retained.turns.values.contains { $0.items["answer"] != nil })
    }

    @Test func failedHistoryInspectionIsRetriedUntilAReadableCheckpointProvesExhaustion() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let recovery = directory.appending(path: "recovery/\(id)/incident/original")
        try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        let durable = Data("Unique recovery bytes".utf8)
        try durable.write(to: recovery)
        let source = directory.appending(path: "\(id).json")
        let unreadable = Data("Temporarily unreadable checkpoint".utf8)
        try unreadable.write(to: source)
        let metrics = PersistenceMetrics()
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, budgetBytes: 1,
            primaryBudgetBytes: 512 * 1_024 * 1_024, metrics: metrics)
        var active = ConversationState(conversationID: UUID(), threadID: "active")
        active.merge(history(items: [.agentMessage(id: "active-answer", text: "Still working")], threadID: "active"))
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        #expect(metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count == 1)
        #expect(try Data(contentsOf: source) == unreadable)
        var repaired = ConversationState(conversationID: id, threadID: "repaired")
        let pending = ChatMessage(role: .user, text: "Unique pending send")
        repaired.submit(pending)
        repaired.merge(history(items: [.agentMessage(id: "answer", text: "Rebuildable remote history")], threadID: "repaired"))
        try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: true, checkpoint: repaired.checkpoint)).write(to: source)
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        #expect(metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count == 2)
        active.markPersistedChange()
        try await store.save(active.checkpoint, conversationID: active.conversationID)
        #expect(metrics.snapshot()[.checkpoints]?.checkpoint?.phases["historyShedRead"]?.count == 2)
        let retained = try #require(try await store.load(id))
        #expect(retained.submissions[pending.id]?.message == pending)
        #expect(retained.turns.values.allSatisfy { $0.items["answer"] == nil })
        #expect(try Data(contentsOf: recovery) == durable)
    }

    @Test(arguments: ImageChange.allCases)
    func rollbackSettledImagesRequireDurableContentAbsorption(change: ImageChange) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        let image = CodexImageAttachment(id: ChatMessage.deterministicID(for: "rollback-settled-image"),
            data: Data(repeating: 41, count: 8_192), format: .jpeg, pixelSize: .init(width: 100, height: 100))
        let changed = CodexImageAttachment(id: image.id,
            data: change == .bytes ? Data(repeating: 42, count: 8_192) : image.data,
            format: change == .format ? .png : image.format,
            pixelSize: change == .dimensions ? .init(width: 200, height: 100) : image.pixelSize)
        let message = ChatMessage(id: ChatMessage.deterministicID(for: "rollback-settled-message"), role: .user,
            text: "Retained local image", attachments: [.inline(image)], date: Date(timeIntervalSince1970: 1))
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.submit(message)
        state.merge(history(items: [.userMessage(id: "canonical-echo", content: [.text(text: message.text, textElements: [])],
            clientId: message.id.uuidString)], turnID: "canonical-turn", threadID: "thread"))
        #expect(state.submissions.isEmpty)
        let fixture = directory.appending(path: "fixture")
        let writer = ConversationCheckpointStore(hostID: host, directory: fixture, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await writer.save(state.checkpoint, conversationID: id)
        let database = try Data(contentsOf: fixture.appending(path: "\(id).sqlite"))
        let wal = try Data(contentsOf: fixture.appending(path: "\(id).sqlite-wal"))
        try database.write(to: directory.appending(path: "\(id).sqlite"))
        try wal.write(to: directory.appending(path: "\(id).sqlite-wal"))
        var turn = try #require(state.turns["canonical-turn"])
        turn.items["canonical-echo"]?.localMessage?.attachments = [MessageAttachment(id: image.id, content: .imageData(changed))]
        state.turns[turn.id] = turn
        state.markPersistedChange()
        let json = directory.appending(path: "\(id).json")
        let rollback = try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: true, checkpoint: state.checkpoint))
        try rollback.write(to: json)
        let store = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var restored = try #require(try await store.load(id))
        guard case .imageData(let loaded) = restored.turns[turn.id]?.items["canonical-echo"]?.localMessage?.attachments.first?.content else {
            Issue.record("The rollback image must remain usable"); return
        }
        #expect(loaded == changed)
        #expect(try Data(contentsOf: json) == rollback)
        restored.persistenceRevision = restored.durableRevision + 1
        try await store.save(restored, conversationID: id)
        #expect(!FileManager.default.fileExists(atPath: json.path))
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Cold image eviction pressure")], threadID: "recent"))
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        let saved = try #require(try await cold.load(id))
        guard case .imageData(let retained) = saved.turns[turn.id]?.items["canonical-echo"]?.localMessage?.attachments.first?.content else {
            Issue.record("The changed image must survive cold eviction"); return
        }
        #expect(retained == changed)
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == database })
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == wal })
        withExtendedLifetime(writer) {}
    }

    @Test(arguments: ImageChange.allCases)
    func canonicalEchoPreservesConflictingInitialSidecarImages(change: ImageChange) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let controlDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: controlDirectory)
        }
        let host = UUID()
        let id = UUID()
        let image = CodexImageAttachment(id: ChatMessage.deterministicID(for: "canonical-conflicting-image"),
            data: Data(repeating: 41, count: 8_192), format: .jpeg, pixelSize: .init(width: 100, height: 100))
        let changed = CodexImageAttachment(id: image.id,
            data: change == .bytes ? Data(repeating: 42, count: 8_192) : image.data,
            format: change == .format ? .png : image.format,
            pixelSize: change == .dimensions ? .init(width: 200, height: 100) : image.pixelSize)
        let message = ChatMessage(id: ChatMessage.deterministicID(for: "canonical-conflicting-message"), role: .user,
            text: "Retained local image", attachments: [.inline(image)], date: Date(timeIntervalSince1970: 1))
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.submit(message)
        state.merge(history(items: [.userMessage(id: "canonical-echo", content: [.text(text: message.text, textElements: [])],
            clientId: message.id.uuidString)], turnID: "canonical-turn", threadID: "thread"))
        #expect(state.submissions.isEmpty)
        var changedMessage = message
        changedMessage.attachments = [MessageAttachment(id: image.id, content: .imageData(changed))]
        var pending = ConversationState(conversationID: id, threadID: "thread")
        pending.submit(changedMessage)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: pending.persistenceRevision, threadID: "thread",
            submission: try #require(pending.submissions[message.id]))
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 64 * 1_024)
        try await store.saveSubmission(record, conversationID: id, generation: await store.generation(for: id))
        let sidecar = directory.appending(path: "\(id).submissions/\(message.id).json")
        let original = try Data(contentsOf: sidecar)
        try await store.save(state.checkpoint, conversationID: id)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == original })
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 64 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Cold sidecar image eviction pressure")], threadID: "recent"))
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        let saved = try #require(try await cold.load(id))
        guard case .imageData(let active) = saved.turns["canonical-turn"]?.items["canonical-echo"]?.localMessage?.attachments.first?.content else {
            Issue.record("The active canonical image must remain usable"); return
        }
        #expect(active == image)
        let recovered = try #require(try recoveredCheckpointFiles(id, directory: directory).first { try Data(contentsOf: $0) == original })
        let preserved = try JSONDecoder().decode(ConversationCheckpointStore.SubmissionRecord.self, from: Data(contentsOf: recovered))
        guard case .imageData(let preservedImage) = preserved.submission.message.attachments.first?.content else {
            Issue.record("The conflicting sidecar image must remain recoverable"); return
        }
        #expect(preservedImage == changed)
        let control = ConversationCheckpointStore(hostID: host, directory: controlDirectory, primaryBudgetBytes: 64 * 1_024)
        try await control.save(state.checkpoint, conversationID: id)
        let probe = ChatMessage(role: .user, text: String(repeating: "probe", count: 32_768), date: Date(timeIntervalSince1970: 1))
        let expected = try await admissionTotal(control, probe: probe)
        #expect(try await admissionTotal(store, probe: probe) == expected + original.count)
        #expect(try await admissionTotal(cold, probe: probe) == expected + original.count)
        #expect(try Data(contentsOf: recovered) == original)
        withExtendedLifetime(store) {}
        withExtendedLifetime(control) {}
    }

    @Test(arguments: ["", " \n\t ", " \nKeep original presentation\t "], [false, true])
    func canonicalEchoRetiresOnlyAbsorbedInitialSidecars(input: String, conflicting: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let controlDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: controlDirectory)
        }
        let host = UUID()
        let id = UUID()
        let image = CodexImageAttachment(id: ChatMessage.deterministicID(for: "canonical-sidecar-image"),
            data: Data(repeating: 41, count: 8_192), format: .jpeg, pixelSize: .init(width: 100, height: 100))
        let message = ChatMessage(id: ChatMessage.deterministicID(for: "canonical-sidecar-message"), role: .user,
            text: input, attachments: [.inline(image)], date: Date(timeIntervalSince1970: 1))
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.submit(message, input: input)
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 64 * 1_024)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: state.persistenceRevision, threadID: "thread",
            submission: try #require(state.submissions[message.id]))
        try await store.saveSubmission(record, conversationID: id, generation: await store.generation(for: id))
        let sidecar = directory.appending(path: "\(id).submissions/\(message.id).json")
        let original = try Data(contentsOf: sidecar)
        let reference = CodexAppServerV2.ImageReference.inline(url: "data:image/jpeg;base64," + image.data.base64EncodedString())
        var content: [CodexAppServerV2.UserInput] = []
        if conflicting { content.append(.text(text: "Different provider input", textElements: [])) }
        else if input == " \nKeep original presentation\t " {
            content.append(.text(text: "Keep original presentation", textElements: []))
        }
        content.append(.image(reference))
        state.merge(history(items: [.userMessage(id: "canonical-echo", content: content, clientId: message.id.uuidString)], threadID: "thread"))
        #expect(state.submissions.isEmpty)
        try await store.save(state.checkpoint, conversationID: id)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        let recovery = directory.appending(path: "recovery/\(id)")
        if conflicting {
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == original })
        } else { #expect(!FileManager.default.fileExists(atPath: recovery.path)) }
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 64 * 1_024)
        var restored = ConversationState(conversationID: id, threadID: "thread")
        restored.restore(try #require(try await cold.load(id)))
        let projected = try #require(ConversationProjection.project(restored).messages.first { $0.id == message.id })
        #expect(projected.text == input)
        #expect(projected.date == message.date)
        #expect(projected.attachments.first?.id == image.id)
        guard case .image(let canonical) = projected.attachments.first?.content else { Issue.record("Canonical image must remain visible"); return }
        #expect(canonical == reference)
        let control = ConversationCheckpointStore(hostID: host, directory: controlDirectory, primaryBudgetBytes: 64 * 1_024)
        try await control.save(state.checkpoint, conversationID: id)
        let probe = ChatMessage(role: .user, text: String(repeating: "probe", count: 32_768), date: Date(timeIntervalSince1970: 1))
        let expected = try await admissionTotal(control, probe: probe)
        let warmCharge = try await admissionTotal(store, probe: probe)
        let coldCharge = try await admissionTotal(cold, probe: probe)
        if conflicting {
            #expect(warmCharge == expected + original.count)
            #expect(coldCharge == expected + original.count)
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == original })
        } else {
            #expect(warmCharge == expected)
            #expect(coldCharge == expected)
            #expect(!FileManager.default.fileExists(atPath: recovery.path))
        }
        withExtendedLifetime(store) {}
        withExtendedLifetime(control) {}
    }

    @Test(arguments: ["lower", "newer", "conflicting"])
    func rollbackSidecarRequiresIdentityAndContentAbsorptionBeforeCleanup(scenario: String) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        let original = ChatMessage(id: ChatMessage.deterministicID(for: "original-sidecar-primary"), role: .user,
            text: "Original SQLite local input", date: Date(timeIntervalSince1970: 1))
        var primary = ConversationState(conversationID: id, threadID: "thread")
        primary.submit(original)
        var checkpoint = primary.checkpoint
        checkpoint.persistenceRevision = 100
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await writer.save(checkpoint, conversationID: id)
        var rollback = ConversationState(conversationID: id, threadID: "thread")
        let jsonMessage = ChatMessage(role: .user, text: "Rollback JSON input", date: Date(timeIntervalSince1970: 2))
        rollback.submit(jsonMessage)
        try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: true, checkpoint: rollback.checkpoint))
            .write(to: directory.appending(path: "\(id).json"))
        var pending = ConversationState(conversationID: id, threadID: "thread")
        let message = ChatMessage(id: scenario == "conflicting" ? original.id : ChatMessage.deterministicID(for: "rollback-sidecar-local"),
            role: .user, text: "Rollback sidecar input", date: Date(timeIntervalSince1970: 3))
        pending.submit(message, input: "Exact sidecar provider input")
        pending.submissions[message.id]?.status = .failed
        pending.submissions[message.id]?.deliveryError = "Rollback host unavailable"
        let record = ConversationCheckpointStore.SubmissionRecord(revision: scenario == "lower" ? 2 : 500, threadID: "thread",
            submission: try #require(pending.submissions[message.id]))
        let folder = directory.appending(path: "\(id).submissions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(message.id).json")
        let bytes = try JSONEncoder().encode(record)
        try bytes.write(to: file)
        let store = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var restored = try #require(try await store.load(id))
        if scenario == "conflicting" {
            #expect(restored.submissions[message.id]?.message == original)
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == bytes })
        } else {
            #expect(restored.submissions[message.id]?.message == message)
            #expect(restored.submissions[message.id]?.input == record.submission.input)
            #expect(restored.submissions[message.id]?.status == .failed)
            #expect(restored.submissions[message.id]?.deliveryError == record.submission.deliveryError)
        }
        restored.persistenceRevision = restored.durableRevision + 1
        try await store.save(restored, conversationID: id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Cold sidecar eviction pressure")], threadID: "recent"))
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        let saved = try #require(try await cold.load(id))
        #expect(saved.submissions[jsonMessage.id]?.message == jsonMessage)
        #expect(saved.submissions[original.id]?.message == original)
        if scenario == "conflicting" {
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == bytes })
        } else {
            #expect(saved.submissions[message.id]?.message == message)
            #expect(saved.submissions[message.id]?.input == record.submission.input)
            #expect(saved.submissions[message.id]?.status == .failed)
            #expect(saved.submissions[message.id]?.deliveryError == record.submission.deliveryError)
        }
        withExtendedLifetime(writer) {}
    }

    @Test(arguments: [false, true]) func rollbackJSONLocalWorkSurvivesReupgradeAndColdBudgetPressure(conflicting: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        let sqliteMessage = ChatMessage(id: ChatMessage.deterministicID(for: "sqlite-local"), role: .user,
            text: "SQLite local input", date: Date(timeIntervalSince1970: 1))
        var sqlite = ConversationState(conversationID: id, threadID: "thread")
        sqlite.submit(sqliteMessage)
        var sqliteCheckpoint = sqlite.checkpoint
        sqliteCheckpoint.persistenceRevision = 100
        let fixture = directory.appending(path: "fixture")
        let writer = ConversationCheckpointStore(hostID: host, directory: fixture, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await writer.save(sqliteCheckpoint, conversationID: id)
        for name in ["\(id).sqlite", "\(id).sqlite-wal"] {
            try Data(contentsOf: fixture.appending(path: name)).write(to: directory.appending(path: name))
        }
        let databaseFile = directory.appending(path: "\(id).sqlite")
        let databaseBytes = try Data(contentsOf: databaseFile)
        let walBytes = try Data(contentsOf: directory.appending(path: "\(id).sqlite-wal"))
        var rollback = ConversationState(conversationID: id, threadID: "thread")
        let failed = ChatMessage(id: ChatMessage.deterministicID(for: "rollback-failed"), role: .user,
            text: "Offline rollback input", date: Date(timeIntervalSince1970: 2))
        rollback.submit(failed, input: "Exact rollback provider input")
        rollback.submissions[failed.id]?.status = .failed
        rollback.submissions[failed.id]?.deliveryError = "Host unavailable"
        if conflicting {
            var changed = sqliteMessage
            changed.text = "Conflicting rollback local input"
            rollback.submit(changed)
        }
        let json = directory.appending(path: "\(id).json")
        let original = try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: true, checkpoint: rollback.checkpoint))
        try original.write(to: json)
        let store = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var restored = try #require(try await store.load(id))
        #expect(restored.submissions[failed.id]?.message == failed)
        #expect(restored.submissions[failed.id]?.input == "Exact rollback provider input")
        #expect(restored.submissions[failed.id]?.status == .failed)
        #expect(restored.submissions[failed.id]?.deliveryError == "Host unavailable")
        #expect(restored.submissions[sqliteMessage.id]?.message.text == (conflicting ? "Conflicting rollback local input" : sqliteMessage.text))
        if conflicting {
            #expect(try Data(contentsOf: json) == original)
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == databaseBytes })
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == walBytes })
        } else {
            #expect(!FileManager.default.fileExists(atPath: json.path))
            #expect(try await ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
                .load(id)?.submissions[failed.id]?.status == .failed)
        }
        restored.persistenceRevision = restored.durableRevision + 1
        try await store.save(restored, conversationID: id)
        #expect(!FileManager.default.fileExists(atPath: json.path))
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Budget pressure")], threadID: "recent"))
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        let saved = try #require(try await cold.load(id))
        #expect(saved.submissions[failed.id]?.message == failed)
        #expect(saved.submissions[failed.id]?.input == "Exact rollback provider input")
        #expect(saved.submissions[failed.id]?.status == .failed)
        #expect(saved.submissions[failed.id]?.deliveryError == "Host unavailable")
        if conflicting {
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == databaseBytes })
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == walBytes })
        } else {
            #expect(saved.submissions[sqliteMessage.id]?.message == sqliteMessage)
        }
        withExtendedLifetime(writer) {}
    }

    @Test(arguments: ["turns", "submissions", "historyWindow"])
    func malformedSplitHeaderLocalWorkSurvivesColdLoadSaveAndEviction(field: String) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        var rebuildable = ConversationState(conversationID: id, threadID: "thread")
        rebuildable.merge(history(items: [.agentMessage(id: "remote", text: "Rebuildable history")], threadID: "thread"))
        let fixture = directory.appending(path: "fixture")
        let writer = ConversationCheckpointStore(hostID: host, directory: fixture, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await writer.save(rebuildable.checkpoint, conversationID: id)
        var local = ConversationState(conversationID: id, threadID: "thread")
        let message = ChatMessage(id: ChatMessage.deterministicID(for: "hidden-header-local"), role: .user,
            text: "Original hidden local submission", date: Date(timeIntervalSince1970: 1))
        local.merge(history(items: [.userMessage(id: "echo", content: [.text(text: message.text, textElements: [])],
            clientId: message.id.uuidString)], threadID: "thread"))
        local.submit(message, input: "Original hidden provider input")
        local.submissions[message.id]?.status = .failed
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(local.checkpoint))
        let hidden = try #require(encoded.objectValue?[field])
        let file = directory.appending(path: "\(id).sqlite")
        let database = try CheckpointDatabase(url: fixture.appending(path: "\(id).sqlite"), access: .persistence)
        let rows = try database.read()
        let header = try #require(rows.first { $0.key == "header" })
        var envelope = try #require(JSONDecoder().decode(JSONValue.self, from: header.data).objectValue)
        var checkpoint = try #require(envelope["checkpoint"]?.objectValue)
        checkpoint[field] = hidden
        envelope["checkpoint"] = .object(checkpoint)
        let malformed = try JSONEncoder().encode(JSONValue.object(envelope))
        _ = try database.replace([.init(key: "header", data: malformed)], retaining: Set(rows.map(\.key)))
        for name in ["\(id).sqlite", "\(id).sqlite-wal"] {
            try Data(contentsOf: fixture.appending(path: name)).write(to: directory.appending(path: name))
        }
        let original = try Data(contentsOf: file)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let originalWAL = FileManager.default.fileExists(atPath: wal.path) ? try Data(contentsOf: wal) : nil
        let store = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Cold budget pressure")], threadID: "recent"))
        try await store.save(recent.checkpoint, conversationID: recent.conversationID)
        #expect(try Data(contentsOf: file) == original)
        #expect(try await store.load(id) == nil)
        var fresh = ConversationState(conversationID: id, threadID: "thread")
        let new = ChatMessage(role: .user, text: "Fresh durable input")
        fresh.submit(new)
        try await store.save(fresh.checkpoint, conversationID: id)
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        recent.markPersistedChange()
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        #expect(try await cold.load(id)?.submissions[new.id]?.message.text == new.text)
        let recovered = try recoveredCheckpointFiles(id, directory: directory)
        #expect(try recovered.contains {
            guard $0.lastPathComponent == file.lastPathComponent else { return false }
            return try Data(contentsOf: $0) == original
        })
        if let originalWAL {
            #expect(try recovered.contains {
                guard $0.lastPathComponent == wal.lastPathComponent else { return false }
                return try Data(contentsOf: $0) == originalWAL
            })
        }
        withExtendedLifetime(writer) {}
        withExtendedLifetime(database) {}
    }

    @Test func failedWarmInvalidationKeepsResidualBytesChargedBeforeAnotherAdmission() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID()
        let residual = Data(String(repeating: "Failed pending cleanup", count: 128).utf8)
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: residual.count)
        var old = ConversationState(conversationID: id, threadID: "old")
        old.merge(history(items: [.agentMessage(id: "old", text: "Rebuildable cache")], threadID: "old"))
        try await store.save(old.checkpoint, conversationID: id)
        let file = directory.appending(path: "\(id).json")
        try residual.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) { try await store.remove(id) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try Data(contentsOf: file) == residual)
        let sender = await ConversationSession.make(conversationID: UUID(), threadID: "new", checkpoints: store)
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
            _ = try await sender.submitDurably(ChatMessage(role: .user, text: "Residual bytes still consume capacity"))
        }
        #expect(await sender.snapshot().messages.isEmpty)
        #expect(try Data(contentsOf: file) == residual)
    }

    @Test func warmSidecarRecoveryDoesNotChargeReadableRemoteHistory() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 8 * 1_024)
        let generation = await store.generation(for: id)
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.submit(ChatMessage(role: .user, text: "Small local input"))
        state.merge(history(items: [.agentMessage(id: "remote", text: String(repeating: "Rebuildable history", count: 2_048))], threadID: "thread"))
        try await store.save(state.checkpoint, conversationID: id, generation: generation)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        try await session.restore()
        let folder = directory.appending(path: "\(id).submissions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let corrupt = Data("Unreadable later submission".utf8)
        try corrupt.write(to: folder.appending(path: "\(UUID()).json"))
        let message = ChatMessage(role: .user, text: "New small durable submission")
        _ = try await session.submitDurably(message)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(message.id).json").path))
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == corrupt })
        let saved = try #require(try await store.load(id, generation: generation))
        #expect(saved.submissions[message.id]?.message.text == message.text)
        #expect(saved.turns.values.flatMap { $0.items.values }.contains { $0.value.id == "remote" })
        await store.release(id, generation: generation)
    }

    @Test(arguments: [false, true]) func quietSettledImagesYieldCapacityAcrossCanonicalFormats(json: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        var state = ConversationState(conversationID: id, threadID: "thread")
        var settled: [ChatMessage] = []
        for index in 1...3 {
            let image = CodexImageAttachment(id: UUID(), data: Data(repeating: UInt8(index), count: 8_192), format: .jpeg,
                pixelSize: .init(width: 100, height: 100))
            let message = ChatMessage(role: .user, text: "Settled \(index)", attachments: [.inline(image)], date: Date(timeIntervalSince1970: Double(index)))
            state.submit(message)
            state.merge(history(items: [.userMessage(id: "echo-\(index)", content: [.text(text: message.text, textElements: [])],
                clientId: message.id.uuidString)], turnID: "turn-\(index)", threadID: "thread"))
            settled.append(message)
        }
        let pendingImage = CodexImageAttachment(id: UUID(), data: Data(repeating: 4, count: 8_192), format: .jpeg,
            pixelSize: .init(width: 100, height: 100))
        let pending = ChatMessage(role: .user, text: "Pending", attachments: [.inline(pendingImage)], date: Date(timeIntervalSince1970: 0))
        state.submit(pending)
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        if json {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: true, checkpoint: state.checkpoint))
                .write(to: directory.appending(path: "\(id).json"))
        } else {
            try await writer.save(state.checkpoint, conversationID: id)
        }
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 40 * 1_024)
        let generation = await store.generation(for: id)
        _ = try await store.load(id, generation: generation)
        let sender = await ConversationSession.make(conversationID: UUID(), threadID: "other", checkpoints: store)
        let message = ChatMessage(role: .user, text: "Capacity must be reclaimable in a quiet conversation")
        _ = try await sender.submitDurably(message)
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 40 * 1_024)
        let restored = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: cold)
        try await restored.restore()
        let snapshot = await restored.snapshot()
        for message in settled.prefix(2) {
            let item = try #require(snapshot.messages.first { $0.id == message.id })
            #expect(item.attachments.first?.id == message.attachments.first?.id)
            guard case .unavailableImage = item.attachments.first?.content else { Issue.record("Oldest quiet images must be shed"); continue }
        }
        let newest = try #require(snapshot.messages.first { $0.id == settled[2].id })
        guard case .imageData = newest.attachments.first?.content else { Issue.record("Newer settled image must survive"); return }
        let saved = try #require(try await cold.load(id))
        guard case .imageData(let image) = saved.submissions[pending.id]?.message.attachments.first?.content else { Issue.record("Pending image must survive"); return }
        #expect(image == pendingImage)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(id).json").path))
        await store.release(id, generation: generation)
        withExtendedLifetime(writer) {}
    }

    @Test(arguments: [false, true]) func readableOverCapacityLegacyImportOpensWithoutPublishingOrLosingItsCharge(removeSource: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let id = UUID()
        let source = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        var root = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: source)).objectValue)
        var timelines = try #require(root["timelines"]?.arrayValue)
        var local = try #require(timelines[0].objectValue)
        local["id"] = .string("legacy-local-seg-0")
        local["events"] = .array([.object(["id": .string("legacy-local-command"), "sequence": .number(1), "kind": .string("command"),
            "title": .string(String(repeating: "Unrebuildable local detail", count: 128)), "details": .array([])])])
        timelines.append(.object(local))
        root["timelines"] = .array(timelines)
        let bytes = try JSONEncoder().encode(JSONValue.object(root))
        try bytes.write(to: source)
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        try await session.restore()
        #expect(await session.beginHistoryRead().base == nil)
        let loaded = try #require(try await store.load(id, threadID: "thread"))
        #expect(loaded.containsLocalRecords)
        #expect(loaded.turns.values.flatMap { $0.items.values }.allSatisfy { $0.isLocal })
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(id).sqlite").path))
        #expect(try Data(contentsOf: source) == bytes)
        let sender = await ConversationSession.make(conversationID: UUID(), threadID: "new", checkpoints: store)
        let full = ChatMessage(role: .user, text: "Keep the draft while local storage is full")
        #expect(try await sender.submit(full).messages.map(\.id) == [full.id])
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
            try await sender.persistSubmission(full.id)
        }
        #expect(await sender.snapshot().messages.isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
        if removeSource { try FileManager.default.removeItem(at: source) }
        else { try await store.remove(id) }
        _ = try await sender.submitDurably(ChatMessage(role: .user, text: "Explicit invalidation frees the import charge"))
    }

    @Test(arguments: [false, true]) func legacyImportChargesOnlyMatchingLocalData(matchesThread: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let id = UUID()
        let source = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        var root = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: source)).objectValue)
        var timelines = try #require(root["timelines"]?.arrayValue)
        var timeline = try #require(timelines[0].objectValue)
        timeline["events"] = .array([.object(["id": .string("remote"), "sequence": .number(1), "kind": .string("command"),
            "title": .string(String(repeating: "Remote legacy history", count: 1_024)), "details": .array([])])])
        timelines[0] = .object(timeline)
        root["timelines"] = .array(timelines)
        let bytes = try JSONEncoder().encode(JSONValue.object(root))
        try bytes.write(to: source)
        let store = ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 2 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: matchesThread ? "thread" : "other", checkpoints: store)
        try await session.restore()
        #expect(await session.beginHistoryRead().base == nil)
        let sender = await ConversationSession.make(conversationID: UUID(), threadID: "new", checkpoints: store)
        _ = try await sender.submitDurably(ChatMessage(role: .user, text: "Only local bytes consume capacity"))
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func coldInspectionPreservesTheOriginalMainAndWALBytesBeforeRecovery() async throws {
        let fixture = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let original = fixture.appending(path: "\(id).sqlite")
        let writer = try CheckpointDatabase(url: original, access: .persistence)
        _ = try writer.replace([.init(key: "header", data: Data("Unknown local payload".utf8))], retaining: ["header"])
        let files = [original, URL(fileURLWithPath: original.path + "-wal")]
        let captured = try files.map { (name: $0.lastPathComponent, bytes: try Data(contentsOf: $0)) }
        for (name, bytes) in captured { try bytes.write(to: directory.appending(path: name)) }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(id).sqlite-shm").path))
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        #expect(try await store.load(id) == nil)
        let recovered = try recoveredCheckpointFiles(id, directory: directory)
        for (name, bytes) in captured {
            let file = try #require(recovered.first { $0.lastPathComponent == name })
            #expect(try Data(contentsOf: file) == bytes)
        }
        withExtendedLifetime(writer) {}
    }

    @Test func capacityShedsOldestSettledImagesButNeverPendingImagesOrTheirAttachmentIdentity() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        var state = ConversationState(conversationID: id, threadID: "thread")
        var settled: [ChatMessage] = []
        for index in 1...3 {
            let image = CodexImageAttachment(id: UUID(), data: Data(repeating: UInt8(index), count: 8_192), format: .jpeg,
                pixelSize: .init(width: 100, height: 100))
            let message = ChatMessage(role: .user, text: "Settled \(index)", attachments: [.inline(image)], date: Date(timeIntervalSince1970: Double(index)))
            state.submit(message)
            state.merge(history(items: [.userMessage(id: "echo-\(index)", content: [.text(text: message.text, textElements: [])],
                clientId: message.id.uuidString)], turnID: "turn-\(index)", threadID: "thread"))
            settled.append(message)
        }
        let pendingImage = CodexImageAttachment(id: UUID(), data: Data(repeating: 4, count: 8_192), format: .jpeg,
            pixelSize: .init(width: 100, height: 100))
        let pending = ChatMessage(role: .user, text: "Pending oldest timestamp", attachments: [.inline(pendingImage)], date: Date(timeIntervalSince1970: 0))
        state.submit(pending)
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await writer.save(state.checkpoint, conversationID: id)
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 40 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        try await session.restore()
        await session.appendLocal(ChatMessage(role: .codex, text: "Checkpoint must remain writable"))
        try await session.flush()
        let snapshot = await session.snapshot()
        for message in settled.prefix(2) {
            let restored = try #require(snapshot.messages.first { $0.id == message.id })
            #expect(restored.attachments.first?.id == message.attachments.first?.id)
            guard case .unavailableImage = restored.attachments.first?.content else { Issue.record("Oldest settled image must be explicitly unavailable"); continue }
        }
        let newest = try #require(snapshot.messages.first { $0.id == settled[2].id })
        guard case .imageData = newest.attachments.first?.content else { Issue.record("Newer settled image should survive"); return }
        let saved = try #require(try await store.load(id))
        guard case .imageData(let image) = saved.submissions[pending.id]?.message.attachments.first?.content else { Issue.record("Pending image must never be shed"); return }
        #expect(image == pendingImage)
        try await session.flush()
        let cold = await ConversationSession.make(conversationID: id, threadID: "thread",
            checkpoints: ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 40 * 1_024))
        try await cold.restore()
        let restored = try #require(await cold.snapshot().messages.first { $0.id == settled[0].id })
        guard case .unavailableImage = restored.attachments.first?.content else { Issue.record("The shed image must not return after reopen"); return }
        #expect(restored.attachments.first?.preview == "Image unavailable")
    }

    @Test func canonicalImageOrderSurvivesPartialReleaseAndLaterAuthoritativeRecovery() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let images = (1...2).map { CodexImageAttachment(id: UUID(), data: Data(repeating: UInt8($0), count: 64), format: .jpeg,
            pixelSize: .init(width: 1, height: 1)) }
        let message = ChatMessage(role: .user, text: "Two images", attachments: images.map(MessageAttachment.inline))
        state.submit(message)
        let references = images.map { CodexAppServerV2.ImageReference.inline(url: "data:image/jpeg;base64," + $0.data.base64EncodedString()) }
        state.merge(history(items: [.userMessage(id: "echo", content: [.image(references[0]), .image(.file(id: "opaque-unfetchable"))],
            clientId: message.id.uuidString)], threadID: "thread"))
        let partial = try #require(ConversationProjection.project(state).messages.first)
        guard case .image = partial.attachments[0].content, case .imageData = partial.attachments[1].content else { Issue.record("Only the proven canonical image can replace bytes"); return }
        state.applyUnavailableImages([message.id: [images[1].id]])
        state.merge(history(items: [.userMessage(id: "echo", content: references.map { .image($0) }, clientId: message.id.uuidString)], threadID: "thread"))
        let restored = try #require(ConversationProjection.project(state).messages.first)
        for index in 0..<2 {
            #expect(restored.attachments[index].id == images[index].id)
            guard case .image(let reference) = restored.attachments[index].content else { Issue.record("Later authoritative bytes must restore the placeholder"); continue }
            #expect(reference == references[index])
        }
    }

    @Test func matchingCanonicalImagesReplaceLocalBytesAndRenderFromHistory() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let image = CodexImageAttachment(id: UUID(), data: Data(repeating: 71, count: 8_192), format: .jpeg,
            pixelSize: .init(width: 100, height: 100))
        let message = ChatMessage(role: .user, text: "Display caption", attachments: [.inline(image)])
        state.submit(message)
        let reference = CodexAppServerV2.ImageReference.inline(url: "data:image/jpeg;base64," + image.data.base64EncodedString())
        state.merge(history(items: [.userMessage(id: "echo", content: [.text(text: "Provider text", textElements: []), .image(reference)],
            clientId: message.id.uuidString)], threadID: "thread"))
        #expect(state.submissions.isEmpty)
        let encoded = try JSONEncoder().encode(state.checkpoint.localRecords)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(image.data.base64EncodedString()))
        let projected = try #require(ConversationProjection.project(state).messages.first)
        #expect(projected.text == message.text)
        #expect(projected.attachments.first?.id == image.id)
        guard case .image(let canonical) = projected.attachments.first?.content else { Issue.record("Image must render from canonical content"); return }
        #expect(canonical == reference)
    }

    @Test func settlementFreesPendingChargesAndKeepsUniquePresentationData() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let emptyDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: emptyDirectory)
        }
        let host = UUID()
        let id = UUID()
        let image = CodexImageAttachment(id: UUID(), data: Data(repeating: 65, count: 8_192), format: .jpeg,
            pixelSize: .init(width: 100, height: 100))
        let message = ChatMessage(role: .user, text: "Retained presentation", attachments: [.inline(image)], date: Date(timeIntervalSince1970: 1))
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 64 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        _ = try await session.submitDurably(message)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(id).submissions/\(message.id).json").path))
        try await session.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(id).submissions").path))
        let probe = ChatMessage(role: .user, text: String(repeating: "probe", count: 32_768), date: Date(timeIntervalSince1970: 1))
        let empty = ConversationCheckpointStore(hostID: host, directory: emptyDirectory, primaryBudgetBytes: 64 * 1_024)
        let baseline = try await admissionTotal(empty, probe: probe)
        let pending = try await admissionTotal(store, probe: probe) - baseline
        let constrained = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: pending)
        let newMessage = ChatMessage(role: .user, text: "Send when pending settles")
        let target = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: constrained)
        try await target.restore()
        let sender = await ConversationSession.make(conversationID: UUID(), threadID: "new", checkpoints: constrained)
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) { _ = try await sender.submitDurably(newMessage) }
        let read = await target.beginHistoryRead()
        _ = await target.merge(history(items: [.userMessage(id: "canonical", content: [.text(text: message.text, textElements: [])],
            clientId: message.id.uuidString)], threadID: "thread"), read: read)
        try await target.flush()
        let settled = try await admissionTotal(constrained, probe: probe) - baseline
        #expect(settled < pending)
        #expect(settled > image.data.base64EncodedString().utf8.count)
        let checkpoint = try #require(try await constrained.load(id))
        #expect(checkpoint.submissions.isEmpty)
        let retainedImages = checkpoint.turns.values.flatMap { $0.items.values }.flatMap { $0.localMessage?.attachments ?? [] }.compactMap { attachment -> CodexImageAttachment? in
            if case .imageData(let value) = attachment.content { return value }
            return nil
        }
        #expect(retainedImages == [image])
        _ = try await sender.submitDurably(newMessage)
        print("Settlement charge: pending=\(pending) settled=\(settled) imageBase64=\(image.data.base64EncodedString().utf8.count)")
    }

    private func admissionTotal(_ store: ConversationCheckpointStore, probe: ChatMessage) async throws -> Int {
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "probe", checkpoints: store)
        do {
            _ = try await session.submitDurably(probe)
            Issue.record("The measurement probe must exceed primary admission")
            return 0
        } catch let failure as ConversationCheckpointStore.CapacityOverflow { return failure.requestedBytes }
    }

    @Test func unreadableRollbackImportKeepsItsSourceAndStartsFreshHistory() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let id = UUID()
        let file = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        let original = Data("Unreadable rollback source".utf8)
        try original.write(to: file)
        let host = UUID()
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 64 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        try await session.restore()
        #expect(await session.beginHistoryRead().base == nil)
        let message = ChatMessage(role: .user, text: "Fresh durable input")
        _ = try await session.submitDurably(message)
        try await session.flush()
        #expect(try Data(contentsOf: file) == original)
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == original })
        #expect(try await store.load(id)?.submissions[message.id]?.message.text == message.text)
    }

    @Test func markerReclamationFailurePreservesAccountingAndThrowsBeforeAdmission() async throws {
        let temporary = TemporaryHostStorage()
        let host = UUID()
        let id = UUID()
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        let folder = directory.appending(path: "\(id).submissions")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            temporary.cleanUp()
        }
        let source = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await store.remove(id)
        var other = ConversationState(conversationID: UUID(), threadID: "other")
        other.merge(history(items: [.agentMessage(id: "other", text: "Initialize cold accounting")], threadID: "other"))
        try await store.save(other.checkpoint, conversationID: other.conversationID)
        let before = await store.accountedDiskBytes
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "pending.json")
        let pending = Data("Later durable submission bytes".utf8)
        try pending.write(to: file)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "new", checkpoints: store)
        await #expect(throws: ConversationCheckpointStore.PreservationFailure.self) {
            _ = try await session.submitDurably(ChatMessage(role: .user, text: "Must fail safely"))
        }
        #expect(await store.accountedDiskBytes >= before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(try Data(contentsOf: file) == pending)
    }

    @Test func decodedContentOverridesProtectionHeaderDisagreement() async throws {
        for format in ["json", "sqlite"] {
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let host = UUID()
            let id = UUID()
            var state = ConversationState(conversationID: id, threadID: "thread")
            let message = ChatMessage(role: .user, text: "Preserve fully decoded local content")
            state.submit(message)
            let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
            if format == "json" {
                let data = try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: false, checkpoint: state.checkpoint))
                try data.write(to: directory.appending(path: "\(id).json"))
            } else {
                try await writer.save(state.checkpoint, conversationID: id)
                let db = try CheckpointDatabase(url: directory.appending(path: "\(id).sqlite"), access: .persistence)
                let rows = try db.read()
                let header = try #require(rows.first { $0.key == "header" })
                var object = try #require(JSONSerialization.jsonObject(with: header.data) as? [String: Any])
                object["containsLocalRecords"] = false
                _ = try db.replace([.init(key: "header", data: JSONSerialization.data(withJSONObject: object))], retaining: Set(rows.map(\.key)))
            }
            let store = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
            #expect(try await store.load(id)?.submissions[message.id]?.message.text == message.text)
            var other = ConversationState(conversationID: UUID(), threadID: "other")
            other.merge(history(items: [.agentMessage(id: "other", text: "Budget pressure")], threadID: "other"))
            try await store.save(other.checkpoint, conversationID: other.conversationID)
            #expect(try await store.load(id)?.submissions[message.id]?.message.text == message.text)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "recovery/\(id)").path))
            withExtendedLifetime(writer) {}
        }
    }
    @Test func coldPendingInvalidationKeepsResidualJSONCharged() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let removed = UUID()
        let residual = Data(String(repeating: "preserved recovery bytes", count: 128).utf8)
        let file = directory.appending(path: "\(removed).json")
        try residual.write(to: file)
        let marker = try CheckpointDatabase(url: directory.appending(path: "\(removed).sqlite"), access: .persistence)
        _ = try marker.replace([.init(key: "invalidation", data: Data("\"pending\"".utf8))], retaining: ["invalidation"])
        let cold = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: residual.count)
        let id = UUID()
        let session = await ConversationSession.make(conversationID: id, threadID: "new", checkpoints: cold)
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
            _ = try await session.submitDurably(ChatMessage(role: .user, text: "Must not spend residual bytes"))
        }
        #expect(try Data(contentsOf: file) == residual)
    }

    @Test func quietMixedHistoryDoesNotConsumePrimaryAdmission() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var ids: [UUID] = []
        for index in 0..<3 {
            let id = UUID()
            ids.append(id)
            var state = ConversationState(conversationID: id, threadID: "thread-\(index)")
            state.submit(ChatMessage(role: .user, text: "Keep pending local input \(index)"))
            state.merge(history(items: [.agentMessage(id: "answer", text: String(repeating: "Authoritative remote history ", count: 2_048))], threadID: "thread-\(index)"))
            try await writer.save(state.checkpoint, conversationID: id)
        }
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 16 * 1_024)
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "new", checkpoints: cold)
        _ = try await session.submitDurably(ChatMessage(role: .user, text: "History must not prevent sending"))
        for id in ids {
            let saved = try #require(try await cold.load(id))
            #expect(saved.submissions.count == 1)
            #expect(saved.historyWindow == nil)
        }
    }

    @Test func unreadableSourcesRecoverThenAdmitAndRebuildHistory() async throws {
        for scenario in ["json", "sqlite", "malformed-submissions-false-flag", "warm-json"] {
            let format = scenario == "sqlite" ? "sqlite" : "json"
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID()
            let source = directory.appending(path: "\(id).\(format)")
            let damaged: Data
            if scenario == "malformed-submissions-false-flag" {
                var local = ConversationState(conversationID: id, threadID: "thread")
                local.submit(ChatMessage(role: .user, text: "Original local input behind a false flag"))
                var payload = try #require(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(local.checkpoint)).objectValue)
                payload["submissions"] = .string("Malformed submission payload")
                damaged = try JSONEncoder().encode(JSONValue.object(["containsLocalRecords": .bool(false), "checkpoint": .object(payload)]))
            } else if scenario == "warm-json" {
                damaged = Data(#"{"containsLocalRecords":false,"checkpoint":"unreadable"}"#.utf8)
            } else { damaged = Data("Exact unreadable \(format) bytes".utf8) }
            let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 64 * 1_024)
            if scenario == "warm-json" {
                var rebuildable = ConversationState(conversationID: id, threadID: "thread")
                rebuildable.merge(history(items: [.agentMessage(id: "previous", text: "Previously rebuildable JSON")], threadID: "thread"))
                try JSONEncoder().encode(CheckpointTestEnvelope(containsLocalRecords: false, checkpoint: rebuildable.checkpoint)).write(to: source)
                #expect(try await store.load(id)?.containsLocalRecords == false)
            }
            try damaged.write(to: source)
            let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
            try await session.restore()
            let read = await session.beginHistoryRead()
            #expect(read.base == nil)
            let message = ChatMessage(role: .user, text: "New durable input after recovery")
            _ = try await session.submitDurably(message)
            let gateway = InvalidationHistoryGateway()
            let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory.appending(path: "pages")))
            let loading = Task { try await service.openTail(header: history(items: []).header, base: read.base) }
            await gateway.waitForItems()
            #expect(await gateway.itemRequests == 1)
            await gateway.releaseItems()
            _ = await session.merge(try await loading.value, read: read)
            try await session.flush()
            #expect(await session.snapshot().messages.contains { $0.text == "Authoritative history" })
            #expect(try await store.load(id)?.submissions[message.id]?.message.text == message.text)
            let recovery = directory.appending(path: "recovery/\(id)")
            let incidents = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
            #expect(try incidents.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
                .contains { (try? Data(contentsOf: $0)) == damaged })
            let cold = ConversationCheckpointStore(hostID: UUID(), directory: directory, budgetBytes: 1, primaryBudgetBytes: 64 * 1_024)
            var recent = ConversationState(conversationID: UUID(), threadID: "recent")
            recent.merge(history(items: [.agentMessage(id: "recent", text: "Cold eviction pressure")], threadID: "recent"))
            try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
            #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == damaged })
            #expect(try await cold.load(id)?.submissions[message.id]?.message.text == message.text)
        }
    }

    @Test func invalidationMarkersRetireWithTheirRollbackSourcesOnWarmAccessAndColdScan() async throws {
        for cold in [false, true] {
            let temporary = TemporaryHostStorage()
            defer { temporary.cleanUp() }
            let host = UUID()
            let id = UUID()
            let source = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
            let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
            let database = directory.appending(path: "\(id).sqlite")
            let warm = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
            try await warm.remove(id)
            #expect(FileManager.default.fileExists(atPath: database.path))
            #expect(await warm.accountedDiskBytes > 0)
            var pending = ConversationState(conversationID: id, threadID: "thread")
            let message = ChatMessage(role: .user, text: "Published after completed cleanup")
            pending.submit(message)
            let record = ConversationCheckpointStore.SubmissionRecord(revision: pending.persistenceRevision, threadID: "thread",
                submission: try #require(pending.submissions[message.id]))
            let folder = directory.appending(path: "\(id).submissions")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: folder.appending(path: "\(message.id).json"), options: .atomic)
            try FileManager.default.removeItem(at: source)
            let store = cold ? ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024) : warm
            if cold {
                var other = ConversationState(conversationID: UUID(), threadID: "other")
                other.merge(history(items: [.agentMessage(id: "other", text: "Rebuildable history")], threadID: "other"))
                try await store.save(other.checkpoint, conversationID: other.conversationID)
            } else { _ = try await store.load(id, threadID: "thread") }
            #expect(!FileManager.default.fileExists(atPath: database.path))
            #expect(try await store.load(id, threadID: "thread")?.submissions[message.id]?.message.text == message.text)
            #expect(await store.retainedFenceCount == 0)
        }
    }

    @Test func markerBytesStayProtectedAndAccountedDuringWarmAndColdBudgetEviction() async throws {
        for cold in [false, true] {
            let temporary = TemporaryHostStorage()
            defer { temporary.cleanUp() }
            let host = UUID()
            let id = UUID()
            let source = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
            let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
            let marker = directory.appending(path: "\(id).sqlite")
            let warm = ConversationCheckpointStore(hostID: host, storage: temporary.storage, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
            try await warm.remove(id)
            #expect(await warm.accountedDiskBytes >= (try checkpointFileBytes(id, directory: directory)))
            let store = cold ? ConversationCheckpointStore(hostID: host, storage: temporary.storage, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024) : warm
            let firstID = UUID()
            for conversationID in [firstID, UUID()] {
                var state = ConversationState(conversationID: conversationID, threadID: "cache")
                state.merge(history(items: [.agentMessage(id: "cache", text: "Evictable history")], threadID: "cache"))
                try await store.save(state.checkpoint, conversationID: conversationID)
                let expected = try checkpointFileBytes(id, directory: directory) + checkpointFileBytes(conversationID, directory: directory)
                #expect(await store.accountedDiskBytes >= expected)
                #expect(FileManager.default.fileExists(atPath: marker.path))
                #expect(FileManager.default.fileExists(atPath: source.path))
            }
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(firstID).sqlite").path))
            #expect(try await store.load(id, threadID: "thread") == nil)
        }
    }

    @Test func invalidationWithoutARollbackSourceRequiresHistoryBeforeSavingAnEmptyConversation() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let id = UUID()
        let index = ConversationIndex(hostID: host, storage: temporary.storage)
        let registry = ConversationSessions(hostID: host, sessionIndex: index, contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        _ = await registry.session(conversationID: id, threadID: "thread")
        await registry.invalidate(threadID: "thread")
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        let cold = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: cold)
        try await session.restore()
        let read = await session.beginHistoryRead()
        #expect(read.base == nil)
        try await session.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(id).sqlite").path))
        let gateway = InvalidationHistoryGateway()
        let service = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages")))
        let header = history(items: []).header
        let loading = Task { try await service.openTail(header: header, base: read.base) }
        await gateway.waitForItems()
        #expect(await gateway.itemRequests == 1)
        #expect(await session.snapshot().messages.isEmpty)
        #expect(await session.beginHistoryRead().base == nil)
        await gateway.releaseItems()
        _ = await session.merge(try await loading.value, read: read)
        try await session.flush()
        #expect(await session.snapshot().messages.map(\.text) == ["Authoritative history"])
        #expect(try await cold.load(id)?.historyWindow != nil)
    }

    @Test func primaryAdmissionPreservesDataAtItsBoundaryAndIgnoresOtherHosts() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let id = UUID()
        let pendingID = UUID()
        let producer = ConversationCheckpointStore(hostID: host, storage: temporary.storage,
            primaryBudgetBytes: 512 * 1_024 * 1_024)
        var saved = ConversationState(conversationID: id, threadID: "saved")
        let original = ChatMessage(role: .user, text: "Existing primary checkpoint")
        saved.submit(original)
        try await producer.save(saved.checkpoint, conversationID: id)
        var pending = ConversationState(conversationID: pendingID, threadID: "pending")
        let pendingMessage = ChatMessage(role: .user, text: "Existing standalone submission")
        pending.submit(pendingMessage)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: pending.persistenceRevision, threadID: "pending",
            submission: try #require(pending.submissions[pendingMessage.id]))
        try await producer.saveSubmission(record, conversationID: pendingID, generation: await producer.generation(for: pendingID))
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        let database = try CheckpointDatabase(url: directory.appending(path: "\(id).sqlite"), access: .persistence)
        let pendingFile = directory.appending(path: "\(pendingID).submissions/\(pendingMessage.id).json")
        let pendingBytes = try Data(contentsOf: pendingFile)
        let limit = try database.payloadBytes() + pendingBytes.count
        for otherHost in [UUID()] {
            let other = ConversationCheckpointStore(hostID: otherHost, storage: temporary.storage,
                primaryBudgetBytes: 512 * 1_024 * 1_024)
            try await other.save(saved.checkpoint, conversationID: id)
            try await other.saveSubmission(record, conversationID: pendingID, generation: await other.generation(for: pendingID))
        }
        let constrained = ConversationCheckpointStore(hostID: host, storage: temporary.storage,
            primaryBudgetBytes: limit)
        saved.markPersistedChange()
        try await constrained.save(saved.checkpoint, conversationID: id)
        #expect(try database.payloadBytes() + pendingBytes.count == limit)
        let before = try database.read().map(\.data)
        let blockedID = UUID()
        let session = await ConversationSession.make(conversationID: blockedID, threadID: "blocked", checkpoints: constrained)
        let blocked = ChatMessage(role: .user, text: "Must not be dispatched")
        do {
            _ = try await session.submitDurably(blocked)
            Issue.record("Primary capacity must reject the submission before dispatch")
        } catch let overflow as ConversationCheckpointStore.CapacityOverflow {
            #expect(overflow.limitBytes == limit)
            #expect(overflow.requestedBytes > limit)
        }
        var excess = ConversationState(conversationID: UUID(), threadID: "excess")
        excess.submit(ChatMessage(role: .user, text: "Refuse primary checkpoint growth"))
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
            try await constrained.save(excess.checkpoint, conversationID: excess.conversationID)
        }
        var cache = ConversationState(conversationID: UUID(), threadID: "cache")
        cache.merge(history(items: [.agentMessage(id: "cache", text: String(repeating: "Rebuildable cache ", count: 1_024))], threadID: "cache"))
        try await constrained.save(cache.checkpoint, conversationID: cache.conversationID)
        #expect(try database.read().map(\.data) == before)
        #expect(try Data(contentsOf: pendingFile) == pendingBytes)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(blockedID).submissions/\(blocked.id).json").path))
        #expect(try await constrained.load(id)?.submissions[original.id]?.message.text == original.text)
        #expect(try await constrained.load(pendingID)?.submissions[pendingMessage.id]?.message.text == pendingMessage.text)
    }

    @Test func concurrentPrimaryAdmissionsCannotBothSpendTheSameCapacity() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        var firstState = ConversationState(conversationID: firstID, threadID: "first")
        var secondState = ConversationState(conversationID: secondID, threadID: "second")
        let firstMessage = ChatMessage(role: .user, text: "First admission")
        let secondMessage = ChatMessage(role: .user, text: "Second admission")
        firstState.submit(firstMessage)
        secondState.submit(secondMessage)
        let firstRecord = ConversationCheckpointStore.SubmissionRecord(revision: firstState.persistenceRevision, threadID: "first",
            submission: try #require(firstState.submissions[firstMessage.id]))
        let secondRecord = ConversationCheckpointStore.SubmissionRecord(revision: secondState.persistenceRevision, threadID: "second",
            submission: try #require(secondState.submissions[secondMessage.id]))
        let limit = max(try JSONEncoder().encode(firstRecord).count, try JSONEncoder().encode(secondRecord).count)
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: limit)
        let firstGeneration = await store.generation(for: firstID)
        let secondGeneration = await store.generation(for: secondID)
        let first = Task { try await store.saveSubmission(firstRecord, conversationID: firstID, generation: firstGeneration) }
        let second = Task { try await store.saveSubmission(secondRecord, conversationID: secondID, generation: secondGeneration) }
        var admitted = 0
        var rejected = 0
        for task in [first, second] {
            do { try await task.value; admitted += 1 }
            catch is ConversationCheckpointStore.CapacityOverflow { rejected += 1 }
        }
        #expect(admitted == 1)
        #expect(rejected == 1)
        let recovered = try await [store.load(firstID), store.load(secondID)]
        #expect(recovered.compactMap { $0 }.count == 1)
        await store.release(firstID, generation: firstGeneration)
        await store.release(secondID, generation: secondGeneration)
    }

    @Test func failedPostCommitCleanupKeepsItsPayloadChargedUntilDeletionSucceeds() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let probeDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let id = UUID()
        let folder = directory.appending(path: "\(id).submissions")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: probeDirectory)
        }
        var state = ConversationState(conversationID: id, threadID: "thread")
        let message = ChatMessage(role: .user, text: String(repeating: "Retained submission payload ", count: 1_024))
        state.submit(message)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: state.persistenceRevision, threadID: "thread",
            submission: try #require(state.submissions[message.id]))
        let probe = ConversationCheckpointStore(hostID: UUID(), directory: probeDirectory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await probe.save(state.checkpoint, conversationID: id)
        let probeDatabase = try CheckpointDatabase(url: probeDirectory.appending(path: "\(id).sqlite"), access: .persistence)
        let limit = try probeDatabase.payloadBytes() + JSONEncoder().encode(record).count
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: limit)
        let generation = await store.generation(for: id)
        try await store.saveSubmission(record, conversationID: id, generation: generation)
        let file = folder.appending(path: "\(message.id).json")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        await #expect(throws: (any Error).self) {
            try await store.save(state.checkpoint, conversationID: id, generation: generation)
        }
        #expect(try await store.load(id)?.submissions[message.id]?.message.text == message.text)
        #expect(try Data(contentsOf: file) == original)
        let nextID = UUID()
        var next = ConversationState(conversationID: nextID, threadID: "next")
        let nextMessage = ChatMessage(role: .user, text: "Cannot spend bytes still occupied by failed cleanup")
        next.submit(nextMessage)
        let nextRecord = ConversationCheckpointStore.SubmissionRecord(revision: next.persistenceRevision, threadID: "next",
            submission: try #require(next.submissions[nextMessage.id]))
        let nextGeneration = await store.generation(for: nextID)
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
            try await store.saveSubmission(nextRecord, conversationID: nextID, generation: nextGeneration)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(nextID).submissions/\(nextMessage.id).json").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try await store.save(state.checkpoint, conversationID: id, generation: generation)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await store.saveSubmission(nextRecord, conversationID: nextID, generation: nextGeneration)
        #expect(try await store.load(nextID)?.submissions[nextMessage.id]?.message.text == nextMessage.text)
    }

    @Test func coldSubmissionAdmissionRejectsOlderRevisionsAfterMetadataRetires() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        var state = ConversationState(conversationID: id, threadID: "thread")
        let message = ChatMessage(role: .user, text: "Keep the later durable submission")
        state.submit(message)
        let submission = try #require(state.submissions[message.id])
        let recent = ConversationCheckpointStore.SubmissionRecord(revision: 2, threadID: "thread", submission: submission)
        var olderSubmission = submission
        olderSubmission.message.text = "An older captured submission"
        let older = ConversationCheckpointStore.SubmissionRecord(revision: 1, threadID: "thread", submission: olderSubmission)
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let generation = await writer.generation(for: id)
        try await writer.saveSubmission(recent, conversationID: id, generation: generation)
        await writer.release(id, generation: generation)
        #expect(await writer.retainedRevisionCount == 0)
        let file = directory.appending(path: "\(id).submissions/\(message.id).json")
        let before = try Data(contentsOf: file)
        let cold = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await cold.saveSubmission(older, conversationID: id, generation: await cold.generation(for: id))
        #expect(try Data(contentsOf: file) == before)
        #expect(try await cold.load(id)?.submissions[message.id]?.message.text == message.text)
        #expect(try await cold.load(id)?.durableRevision == 2)
        var replacement = submission
        replacement.message.text = "Newer input for the same client identity"
        let newer = ConversationCheckpointStore.SubmissionRecord(revision: 3, threadID: "thread", submission: replacement)
        try await cold.saveSubmission(newer, conversationID: id, generation: await cold.generation(for: id))
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == before })
        #expect(try await cold.load(id)?.submissions[message.id]?.message.text == replacement.message.text)
        var committed = try #require(try await cold.load(id))
        committed.persistenceRevision = 4
        try await cold.save(committed, conversationID: id)
        var distinct = ConversationState(conversationID: id, threadID: "thread")
        let pending = ChatMessage(role: .user, text: "A distinct earlier submission must still persist")
        distinct.submit(pending)
        let earlier = ConversationCheckpointStore.SubmissionRecord(revision: 1, threadID: "thread",
            submission: try #require(distinct.submissions[pending.id]))
        try await cold.saveSubmission(earlier, conversationID: id, generation: await cold.generation(for: id))
        #expect(try await cold.load(id)?.submissions[pending.id]?.message.text == pending.text)
        #expect(try await cold.load(id)?.submissions[message.id]?.message.text == replacement.message.text)
    }

    @Test func readingManyCheckpointsRetiresUnownedRevisionState() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let writer = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let reader = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        for index in 0..<64 {
            let id = ChatMessage.deterministicID(for: "revision-traversal-\(index)")
            var state = ConversationState(conversationID: id, threadID: "thread-\(index)")
            state.submit(ChatMessage(role: .user, text: "Retain durable local record \(index)"))
            try await writer.save(state.checkpoint, conversationID: id)
            #expect(try await reader.load(id)?.durableRevision == state.persistenceRevision)
            #expect(await reader.retainedRevisionCount <= 16)
        }
    }

    @Test func settledCheckpointOperationsReleaseTheirFenceState() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        for index in 0..<128 {
            let id = ChatMessage.deterministicID(for: "checkpoint-fence-\(index)")
            #expect(try await store.load(id) == nil)
            try await store.remove(id)
            let generation = await store.generation(for: id)
            #expect(await store.retainedFenceCount == 1)
            #expect(try await store.load(id, generation: generation) == nil)
            var state = ConversationState(conversationID: id, threadID: "thread")
            state.merge(history(items: [.agentMessage(id: "answer", text: "Rebuildable history")]))
            try await store.save(state.checkpoint, conversationID: id, generation: generation)
            #expect(try await store.load(id, generation: generation)?.durableRevision == state.persistenceRevision)
            await store.release(id, generation: generation)
            #expect(await store.retainedFenceCount == 0)
        }
    }

    @Test func releasedAndInvalidatedGenerationsNeverBecomeCurrentAgain() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let id = ChatMessage.deterministicID(for: "stale-checkpoint-generation")
        _ = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.submit(ChatMessage(role: .user, text: "Original"))
        let original = await store.generation(for: id)
        try await store.save(state.checkpoint, conversationID: id, generation: original)
        await store.release(id, generation: original)
        #expect(await store.retainedFenceCount == 0)
        let reopened = await store.generation(for: id)
        #expect(reopened != original)
        await store.release(id, generation: original)
        #expect(try await store.load(id, generation: reopened)?.submissions.count == 1)
        await #expect(throws: CancellationError.self) { _ = try await store.load(id, generation: original) }
        await #expect(throws: CancellationError.self) { try await store.save(state.checkpoint, conversationID: id, generation: original) }
        let submission = try #require(state.submissions.values.first)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: state.persistenceRevision + 1, threadID: "thread", submission: submission)
        await #expect(throws: CancellationError.self) { try await store.saveSubmission(record, conversationID: id, generation: original) }
        try await store.remove(id)
        let replacement = await store.generation(for: id)
        #expect(replacement != reopened)
        try Data("Unreadable removed checkpoint".utf8).write(to: directory.appending(path: "\(id).json"))
        #expect(try await store.load(id, generation: replacement) == nil)
        await #expect(throws: CancellationError.self) { _ = try await store.load(id, generation: reopened) }
        try await store.saveSubmission(record, conversationID: id, generation: replacement)
        try FileManager.default.removeItem(at: directory.appending(path: "\(id).json"))
        #expect(try await store.load(id, generation: replacement)?.submissions.count == 1)
        try await store.save(state.checkpoint, conversationID: id, generation: replacement)
        await store.release(id, generation: replacement)
        #expect(await store.retainedFenceCount == 0)
        await #expect(throws: CancellationError.self) { try await store.save(state.checkpoint, conversationID: id, generation: reopened) }
    }

    @Test func invalidationSurvivesRestartWithoutImportingRollbackHistoryOrSavingAnUnknownEmptyTail() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let id = ChatMessage.deterministicID(for: "legacy-invalidation")
        let legacy = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        let original = try Data(contentsOf: legacy)
        let previous = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        #expect(try await previous.load(id, threadID: "thread")?.order == ["turn"])
        try await previous.remove(id)
        #expect(await previous.retainedFenceCount == 0)
        let cold = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        #expect(try await cold.load(id, threadID: "thread") == nil)
        #expect(try Data(contentsOf: legacy) == original)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: cold)
        try await session.restore()
        let read = await session.beginHistoryRead()
        #expect(read.base == nil)
        let gateway = InvalidationHistoryGateway()
        let service = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages")))
        let header = history(items: []).header
        let loading = Task { try await service.openTail(header: header, base: read.base) }
        await gateway.waitForItems()
        #expect(await gateway.itemRequests == 1)
        #expect(await session.beginHistoryRead().base == nil)
        try await session.flush()
        #expect(try await cold.load(id, threadID: "thread") == nil)
        await gateway.releaseItems()
        _ = await session.merge(try await loading.value, read: read)
        try await session.flush()
        let restored = try #require(try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(id, threadID: "thread"))
        #expect(restored.historyWindow != nil)
        #expect(await session.snapshot().messages.map(\.text) == ["Authoritative history"])
        let database = try CheckpointDatabase(url: temporary.storage.directory(for: .device)
            .appending(path: "conversations-v1/\(host)/\(id).sqlite"), access: .persistence)
        #expect(try database.readInvalidation() == nil)
        #expect(try Data(contentsOf: legacy) == original)
        let budgetStore = ConversationCheckpointStore(hostID: host, storage: temporary.storage, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Newer rebuildable history")], threadID: "recent"))
        try await budgetStore.save(recent.checkpoint, conversationID: recent.conversationID)
        #expect(try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(id, threadID: "thread") == nil)
        #expect(try Data(contentsOf: legacy) == original)
    }

    @Test func invalidationRetriesFailedCleanupWithoutDeletingALaterSubmissionAfterClearFailure() async throws {
        let temporary = TemporaryHostStorage()
        let host = UUID()
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            temporary.cleanUp()
        }
        let id = UUID()
        _ = try writeCheckpointRollbackSource(id, threadID: "thread", storage: temporary.storage)
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.merge(history(items: [.agentMessage(id: "old", text: "Old history")]))
        try await store.save(state.checkpoint, conversationID: id)
        let json = directory.appending(path: "\(id).json")
        try Data("Stale JSON awaiting invalidation".utf8).write(to: json)
        let submissions = directory.appending(path: "\(id).submissions")
        try FileManager.default.createDirectory(at: submissions, withIntermediateDirectories: true)
        try Data("Stale submission awaiting invalidation".utf8).write(to: submissions.appending(path: "old.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) { try await store.remove(id) }
        #expect(FileManager.default.fileExists(atPath: json.path))
        #expect(await store.retainedFenceCount == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let cold = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        #expect(try await cold.load(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: json.path))
        #expect(!FileManager.default.fileExists(atPath: submissions.path))
        let generation = await cold.generation(for: id)
        var submitted = ConversationState(conversationID: id, threadID: "thread")
        let message = ChatMessage(role: .user, text: "Survive failed marker clear")
        submitted.submit(message)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: submitted.persistenceRevision, threadID: "thread",
            submission: try #require(submitted.submissions[message.id]))
        try await withCheckpointWriterLock(directory.appending(path: "\(id).sqlite")) {
            do {
                try await cold.saveSubmission(record, conversationID: id, generation: generation)
                Issue.record("The competing writer must reject marker clearing")
            } catch let error as CheckpointDatabase.Failure {
                #expect(error.code == SQLITE_BUSY)
            }
            let restored = await ConversationSession.make(conversationID: id, threadID: "thread",
                checkpoints: ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
            try await restored.restore()
            #expect(await restored.snapshot().messages.first?.text == message.text)
            #expect(await restored.deliveryIsUncertain(message.id))
        }
        try await cold.saveSubmission(record, conversationID: id, generation: generation)
        #expect(try await cold.load(id, generation: generation)?.submissions[message.id]?.message.text == message.text)
        let database = try CheckpointDatabase(url: directory.appending(path: "\(id).sqlite"), access: .persistence)
        #expect(try database.readInvalidation() == nil)
    }

    @Test func closedInvalidationDatabasesKeepOnlyASmallCanonicalRecord() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let first = ChatMessage.deterministicID(for: "closed-invalidation-0")
        _ = try writeCheckpointRollbackSource(first, threadID: "populated", storage: temporary.storage)
        var populated = ConversationState(conversationID: first, threadID: "populated")
        populated.merge(history(items: [.agentMessage(id: "large", text: String(repeating: "Previously retained history. ", count: 8_192))], threadID: "populated"))
        try await store.save(populated.checkpoint, conversationID: first)
        #expect(try await store.load(first)?.turns.count == 1)
        for index in 0..<32 {
            let id = ChatMessage.deterministicID(for: "closed-invalidation-\(index)")
            _ = try writeCheckpointRollbackSource(id, threadID: "populated", storage: temporary.storage)
            try await store.remove(id)
        }
        let file = directory.appending(path: "\(first).sqlite")
        let bytes = try Data(contentsOf: file).count
        let auxiliaryFiles = ["-wal", "-shm"].filter { FileManager.default.fileExists(atPath: file.path + $0) }
        #expect(bytes <= 16 * 1_024)
        #expect(auxiliaryFiles.isEmpty)
        #expect(await store.retainedFenceCount == 0)
        print("Closed invalidation storage: \(bytes) bytes, \(auxiliaryFiles.count) auxiliary files")
    }

    @Test func submissionIsDurableWithoutRewritingRetainedHistory() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [.agentMessage(id: "history", text: String(repeating: "Retained history. ", count: 50_000))]))
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await store.save(state.checkpoint, conversationID: state.conversationID)
        let file = directory.appending(path: "\(state.conversationID).sqlite")
        let before = try CheckpointIdentity(file)
        let session = await ConversationSession.make(conversationID: state.conversationID, threadID: "thread", checkpoints: store)
        let message = ChatMessage(role: .user, text: "Small durable send")
        _ = try await session.submitDurably(message)
        #expect(try CheckpointIdentity(file) == before)
        let recordFile = directory.appending(path: "\(state.conversationID).submissions/\(message.id).json")
        #expect(try Data(contentsOf: recordFile).count < 4_096)
        let coldStore = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let cold = await ConversationSession.make(conversationID: state.conversationID, threadID: "thread", checkpoints: coldStore)
        try await cold.restore()
        let recovered = await cold.snapshot()
        #expect(recovered.messages.contains { $0.id == message.id && $0.text == "Small durable send" })
        #expect(recovered.messages.contains { $0.text == String(repeating: "Retained history. ", count: 50_000) })
        await session.accepted(message.id, turnID: "accepted-turn")
        let absorbed = try #require(try await ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024).load(state.conversationID))
        #expect(absorbed.submissions[message.id]?.status == .accepted)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(state.conversationID).submissions").path))
    }

    @Test func unreadableSubmissionBytesArePreservedAndReadableSidecarsStillRestore() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        let session = await ConversationSession.make(conversationID: id, threadID: "thread",
            checkpoints: ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024))
        let unknown = ChatMessage(role: .user, text: "Original unknown submission")
        let readable = ChatMessage(role: .user, text: "Readable pending submission")
        _ = try await session.submitToQueue(unknown, input: unknown.text)
        try await session.persistSubmission(unknown.id)
        _ = try await session.submitToQueue(readable, input: readable.text)
        try await session.persistSubmission(readable.id)
        let record = directory.appending(path: "\(id).submissions/\(unknown.id).json")
        let corrupt = Data("unreadable submission".utf8)
        try corrupt.write(to: record)
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let cold = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        let message = ChatMessage(role: .user, text: "New durable input")
        _ = try await cold.submitDurably(message)
        try await cold.flush()
        let saved = try #require(try await store.load(id))
        #expect(saved.submissions[readable.id]?.message.text == readable.text)
        #expect(saved.submissions[message.id]?.message.text == message.text)
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == corrupt })
    }

    @Test func oldCheckpointCannotOverwriteANewerWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let old = state.checkpoint
        state.submit(ChatMessage(role: .user, text: "Persist me"))
        try await store.save(state.checkpoint, conversationID: state.conversationID)
        try await store.save(old, conversationID: state.conversationID)
        let saved = try #require(try await store.load(state.conversationID))
        #expect(saved.revision == state.revision)
        #expect(saved.submissions.count == 1)
    }

    @Test func checkpointBudgetEvictsOnlyRebuildableHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var local = ConversationState(conversationID: UUID(), threadID: "thread")
        local.submit(ChatMessage(role: .user, text: "Keep my pending send"))
        try await store.save(local.checkpoint, conversationID: local.conversationID)
        var first = ConversationState(conversationID: UUID(), threadID: "thread")
        first.merge(history(items: [.agentMessage(id: "a", text: "Reloadable")]))
        try await store.save(first.checkpoint, conversationID: first.conversationID)
        var second = ConversationState(conversationID: UUID(), threadID: "thread")
        second.merge(history(items: [.agentMessage(id: "b", text: "Recent")]))
        try await store.save(second.checkpoint, conversationID: second.conversationID)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(local.conversationID).sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(first.conversationID).sqlite").path))
        #expect(try await store.load(local.conversationID)?.submissions.count == 1)
    }

    @Test func aColdStoreEvictsOnlyRebuildableCheckpointsItFindsOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let previous = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var local = ConversationState(conversationID: UUID(), threadID: "thread")
        local.submit(ChatMessage(role: .user, text: "Keep my pending send"))
        try await previous.save(local.checkpoint, conversationID: local.conversationID)
        var reloadable = ConversationState(conversationID: UUID(), threadID: "thread")
        reloadable.merge(history(items: [.agentMessage(id: "a", text: "Reloadable")]))
        try await previous.save(reloadable.checkpoint, conversationID: reloadable.conversationID)
        let unreadable = directory.appending(path: "\(UUID()).json")
        try Data("unreadable checkpoint".utf8).write(to: unreadable)

        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var recent = ConversationState(conversationID: UUID(), threadID: "thread")
        recent.merge(history(items: [.agentMessage(id: "b", text: "Recent")]))
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(local.conversationID).sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(reloadable.conversationID).sqlite").path))
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
        #expect(try await cold.load(recent.conversationID) != nil)
    }

    @Test func streamingChangesOnlyTheLiveTailAndPreservesSettledRecords() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let host = UUID()
        var state = ConversationState(conversationID: id, threadID: "thread")
        let retained = String(repeating: "Settled retained history. ", count: 30_000)
        state.merge(history(items: [.agentMessage(id: "settled", text: retained)], status: .completed))
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let prefix = String(repeating: "Live text. ", count: 5_000)
        state.apply(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "answer", text: ""),
            threadID: "thread", turnID: "live", ordinal: 1, startedAtMs: 1000, completedAtMs: 2000))
        state.apply(try GatewayEventFixture.delta(prefix, threadID: "thread", turnID: "live", itemID: "answer"))
        state.commitLiveChanges()
        try await store.save(state.checkpoint, conversationID: id)
        let database = try CheckpointDatabase(url: directory.appending(path: "\(id).sqlite"), access: .persistence)
        let before = Dictionary(uniqueKeysWithValues: try database.read().map { ($0.key, $0.data) })
        let suffix = String(repeating: "New text. ", count: 400)
        state.apply(try GatewayEventFixture.delta(suffix, threadID: "thread", turnID: "live", itemID: "answer"))
        state.commitLiveChanges()
        try await store.save(state.checkpoint, conversationID: id)
        let after = Dictionary(uniqueKeysWithValues: try database.read().map { ($0.key, $0.data) })
        #expect(after["history"] == before["history"])
        #expect(after["turn:turn"] == before["turn:turn"])
        let recovered = try #require(try await ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024).load(id))
        var restored = ConversationState(conversationID: id, threadID: "thread")
        restored.restore(recovered)
        let messages = ConversationProjection.project(restored).messages
        #expect(messages.contains { $0.text == retained })
        #expect(messages.contains { $0.text == prefix + suffix })
        state.turns.removeValue(forKey: "live")
        state.order.removeAll { $0 == "live" }
        state.markPersistedChange()
        try await store.save(state.checkpoint, conversationID: id)
        let trimmed = try #require(try await ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024).load(id))
        #expect(trimmed.turns["live"] == nil)
        #expect(try database.read().allSatisfy { $0.key != "turn:live" })
    }

    @Test func legacyImportCommitsBeforeRemovingTheOriginalAndRetriesFailure() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID()
        let original = try JSONDecoder().decode(JSONValue.self,
            from: ProtocolFixtures.data(at: "checkpoints/sent-attachments-v1.json"))
        let envelope = JSONValue.object(["containsLocalRecords": .bool(true), "checkpoint": original])
        let legacy = directory.appending(path: "\(id).json")
        try JSONEncoder().encode(envelope).write(to: legacy)
        let identity = try FileIdentity(legacy)
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var checkpoint = try #require(try await store.load(id))
        checkpoint.persistenceRevision = checkpoint.durableRevision + 1
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) { try await store.save(checkpoint, conversationID: id) }
        #expect(try FileIdentity(legacy) == identity)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await store.save(checkpoint, conversationID: id)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let imported = try #require(try await ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024).load(id))
        let encoder = JSONEncoder()
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoder.encode(imported)) == JSONDecoder().decode(JSONValue.self, from: encoder.encode(checkpoint)))
        #expect(imported.tokenUsage == nil)
        #expect(imported.submissions.values.first?.message.attachments.count == 4)
    }

    @Test func aDirectWritePreservesAnUnreadableDatabaseInRecovery() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let original = Data("Unreadable durable database".utf8)
        try original.write(to: directory.appending(path: "\(id).sqlite"))
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: id, threadID: "thread")
        state.appendLocal(ChatMessage(role: .codex, text: "New local record"), turnID: nil)
        try await store.save(state.checkpoint, conversationID: id)
        #expect(try recoveredCheckpointFiles(id, directory: directory).contains { try Data(contentsOf: $0) == original })
        #expect(try await store.load(id)?.containsLocalRecords == true)
    }

    @Test func budgetEvictionPreservesMalformedRecordsBehindAValidRebuildableHeader() async throws {
        for scenario in ["cold-unread", "cold-failed", "warm-failed", "missing-history", "equivalent-keys", "invalid-invalidation"] {
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let host = UUID()
            let id = UUID()
            let previous = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
            var state = ConversationState(conversationID: id, threadID: "thread")
            state.merge(history(items: [.agentMessage(id: "retained", text: "Recoverable history")]))
            try await previous.save(state.checkpoint, conversationID: id)
            let file = directory.appending(path: "\(id).sqlite")
            let generation = await previous.generation(for: id)
            _ = try await previous.load(id, generation: generation)
            var database: CheckpointDatabase? = try CheckpointDatabase(url: file, access: .persistence)
            let valid = try #require(database).read()
            let item = try #require(valid.first { $0.key.hasPrefix("item:") })
            var damaged = scenario == "missing-history"
                ? valid.filter { $0.key != "history" }
                : valid.map { $0.key == item.key ? .init(key: $0.key, data: Data("invalid item payload".utf8)) : $0 }
            if scenario == "invalid-invalidation" {
                damaged = [.init(key: "invalidation", data: Data("invalid marker payload".utf8))]
            }
            if scenario == "equivalent-keys" {
                damaged = valid + [.init(key: "unknown:é", data: Data("first".utf8)),
                    .init(key: "unknown:e\u{301}", data: Data("second".utf8)),
                    .init(key: "unknown:z", data: Data("between equivalent keys".utf8))]
            }
            _ = try #require(database).replace(damaged, retaining: Set(damaged.map(\.key)))
            database = nil
            let original = try Data(contentsOf: file)
            let wal = URL(fileURLWithPath: file.path + "-wal")
            let originalWAL = FileManager.default.fileExists(atPath: wal.path) ? try Data(contentsOf: wal) : nil
            let inspected = scenario == "warm-failed" || scenario == "invalid-invalidation" ? previous
                : ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
            if scenario != "cold-unread" {
                #expect(try await inspected.load(id) == nil)
            }
            var recent = ConversationState(conversationID: UUID(), threadID: "recent")
            recent.merge(history(items: [.agentMessage(id: "recent", text: "Recent history")]))
            try await inspected.save(recent.checkpoint, conversationID: recent.conversationID)
            if scenario == "cold-unread" {
                let retained = try CheckpointDatabase(url: file, access: .persistence).read()
                #expect(retained.count == damaged.count)
                for record in damaged {
                    #expect(retained.contains { Array($0.key.utf8) == Array(record.key.utf8) && $0.data == record.data })
                }
            } else {
                let recovery = try recoveredCheckpointFiles(id, directory: directory)
                #expect(try recovery.contains {
                    guard $0.lastPathComponent == file.lastPathComponent else { return false }
                    return try Data(contentsOf: $0) == original
                })
                if let originalWAL {
                    #expect(try recovery.contains {
                        guard $0.lastPathComponent == wal.lastPathComponent else { return false }
                        return try Data(contentsOf: $0) == originalWAL
                    })
                }
            }
            await previous.release(id, generation: generation)
        }
    }

    @Test func emptySubmissionFolderIsRemovedAndDoesNotProtectRebuildableHistory() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var first = ConversationState(conversationID: UUID(), threadID: "thread")
        first.merge(history(items: [.agentMessage(id: "first", text: "Rebuildable history")]))
        try await store.save(first.checkpoint, conversationID: first.conversationID)
        let folder = directory.appending(path: "\(first.conversationID).submissions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await store.save(first.checkpoint, conversationID: first.conversationID)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        var recent = ConversationState(conversationID: UUID(), threadID: "thread")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Recent history")]))
        try await store.save(recent.checkpoint, conversationID: recent.conversationID)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(first.conversationID).sqlite").path))
    }

    @Test func coldBudgetInspectionRepairsEmptyFoldersAndProtectsUnknownSubmissionCoverage() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let previous = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var states: [ConversationState] = []
        for name in ["empty", "nonempty", "unreadable"] {
            var state = ConversationState(conversationID: UUID(), threadID: name)
            state.merge(history(items: [.agentMessage(id: name, text: "Rebuildable history")]))
            try await previous.save(state.checkpoint, conversationID: state.conversationID)
            states.append(state)
        }
        let folders = states.map { directory.appending(path: "\($0.conversationID).submissions") }
        try FileManager.default.createDirectory(at: folders[0], withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folders[1], withIntermediateDirectories: true)
        let unknown = Data("unknown submission".utf8)
        let pending = folders[1].appending(path: "unreadable.json")
        try unknown.write(to: pending)
        try unknown.write(to: folders[2])

        let cold = ConversationCheckpointStore(hostID: host, directory: directory, budgetBytes: 1, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let restored = await ConversationSession.make(conversationID: states[0].conversationID, threadID: "empty", checkpoints: cold)
        try await restored.restore()
        try await restored.flush()
        #expect(FileManager.default.fileExists(atPath: folders[0].path))
        var recent = ConversationState(conversationID: UUID(), threadID: "recent")
        recent.merge(history(items: [.agentMessage(id: "recent", text: "Recent history")]))
        try await cold.save(recent.checkpoint, conversationID: recent.conversationID)
        #expect(!FileManager.default.fileExists(atPath: folders[0].path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(states[0].conversationID).sqlite").path))
        for state in states.dropFirst() {
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(state.conversationID).sqlite").path))
        }
        #expect(try Data(contentsOf: pending) == unknown)
        #expect(try Data(contentsOf: folders[2]) == unknown)
    }


}

private struct CheckpointTestEnvelope: Encodable {
    let containsLocalRecords: Bool
    let checkpoint: ConversationState.Checkpoint
}

private func checkpointFileBytes(_ id: UUID, directory: URL) throws -> Int {
    try ["\(id).sqlite", "\(id).sqlite-wal"].reduce(0) { bytes, name in
        let file = directory.appending(path: name)
        return try bytes + (FileManager.default.fileExists(atPath: file.path) ? Data(contentsOf: file).count : 0)
    }
}

private func writeCheckpointRollbackSource(_ id: UUID, threadID: String, storage: HostStorage) throws -> URL {
    let directory = storage.directory(for: .device).appending(path: "codex-timelines")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source: JSONValue = .object(["version": .number(1), "timelines": .array([.object([
        "id": .string("gw-\(threadID)-turn-seg-0"), "conversationID": .string(id.uuidString), "sessionID": .string(threadID),
        "startedAt": .string("2026-01-01T00:00:00Z"), "anchorDate": .string("2026-01-01T00:00:00Z"),
        "events": .array([.object(["id": .string("gw-\(threadID)-turn-old"), "sequence": .number(1), "kind": .string("command"),
            "title": .string("Rollback history"), "details": .array([])])])
    ])])])
    let file = directory.appending(path: "\(id).json")
    try JSONEncoder().encode(source).write(to: file)
    return file
}

private actor InvalidationHistoryGateway: CodexHistoryGateway {
    let historyHostID = "host"
    private var pending: CheckedContinuation<Data, any Error>?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var itemRequests = 0

    func waitForItems() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "thread/turns/list" {
            return try JSONEncoder().encode(InvalidationHistoryEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
                data: [.init(id: "turn", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)],
                nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/items/list", pending == nil else { throw InvalidationProbeError.unexpected }
        itemRequests += 1
        return try await withCheckedThrowingContinuation {
            pending = $0
            arrival?.resume()
            arrival = nil
        }
    }

    func releaseItems() {
        do {
            let result = CodexAppServerV2.ThreadItemsListResponse(data: [.init(turnId: "turn",
                item: .agentMessage(id: "answer", text: "Authoritative history"), startedAtOrdinal: 1, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)
            pending?.resume(returning: try JSONEncoder().encode(InvalidationHistoryEnvelope(result: result)))
        } catch { pending?.resume(throwing: error) }
        pending = nil
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw InvalidationProbeError.unexpected }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw InvalidationProbeError.unexpected }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse {
        .init(thread: .historyFixture(id: threadID))
    }
}

private enum InvalidationProbeError: Error { case unexpected, writerLock }

private struct InvalidationHistoryEnvelope<Value: Encodable>: Encodable {
    let result: Value
}

private final class CheckpointWriterLock {
    private let connection: OpaquePointer

    init(_ file: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw InvalidationProbeError.writerLock
        }
        guard sqlite3_exec(opened, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            throw InvalidationProbeError.writerLock
        }
        connection = opened
    }

    deinit {
        sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
        sqlite3_close(connection)
    }
}

private func withCheckpointWriterLock(_ file: URL, operation: () async throws -> Void) async throws {
    let lock = try CheckpointWriterLock(file)
    defer { withExtendedLifetime(lock) {} }
    try await operation()
}

private func recoveredCheckpointFiles(_ id: UUID, directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory.appending(path: "recovery/\(id)"), includingPropertiesForKeys: nil)
        .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
}

private extension MessageAttachment {
    static func inline(_ image: CodexImageAttachment) -> MessageAttachment {
        MessageAttachment(id: image.id, content: .imageData(image))
    }
}
