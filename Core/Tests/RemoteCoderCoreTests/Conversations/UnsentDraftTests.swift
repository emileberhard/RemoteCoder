import Foundation
import SwiftData
import Testing
@testable import RemoteCoderCore

@MainActor
struct UnsentDraftTests {
    @Test func blankNewChatDraftsAreNeverStoredAndClearingOneDeletesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let blank = try #require(await store.draft(for: .newChat(UUID())))
        store.setNewChatSetup(setup(folder: "/repo/blank"), in: blank)
        let keptID = UUID()
        let kept = try #require(await store.draft(for: .newChat(keptID)))
        store.setText("Keep this prompt", in: kept)
        #expect(await store.flush())
        #expect(try storedDestinations(in: directory) == [ComposerDraftStore.Destination.newChat(keptID).key])
        #expect(await waitUntil { store.unsentDrafts.map(\.id) == [keptID] })

        store.setText(" \n ", in: kept)
        #expect(await store.flush())
        #expect(try storedDestinations(in: directory).isEmpty)
        #expect(await waitUntil { store.unsentDrafts.isEmpty })
    }

    @Test func summariesCarryTitleSetupAndEditTime() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let textID = UUID()
        let text = try #require(await store.draft(for: .newChat(textID)))
        store.setText("\n  First line  \nSecond line", in: text)
        let edited = text.modifiedAt
        let saved = setup(folder: "/repo/app", model: ClaudeModelCatalog.opusModelID, reasoning: .effort(.high), fast: false)
        store.setNewChatSetup(saved, in: text)
        #expect(text.modifiedAt == edited)
        let fileID = UUID()
        store.setAttachments([file()], in: try #require(await store.draft(for: .newChat(fileID))))
        let threadDraft = try #require(await store.draft(for: .thread("thread")))
        store.setText("A reply, not an unsent chat", in: threadDraft)
        #expect(await store.flush())

        let summaries = Dictionary(uniqueKeysWithValues: try await storedDrafts(in: directory).map { ($0.id, $0) })
        #expect(summaries.count == 2)
        #expect(summaries[textID]?.title == "First line")
        #expect(summaries[textID]?.setup == saved)
        #expect(summaries[textID]?.setup?.reasoningSelection == .effort(.high))
        #expect(summaries[textID]?.modifiedAt == text.modifiedAt)
        #expect(summaries[fileID]?.title == "1 attachment")
        #expect(summaries[fileID]?.setup == nil)

        let reopened = try #require(await ComposerDraftStore(directory: directory).draft(for: .newChat(textID)))
        #expect(reopened.newChat == saved)
        #expect(reopened.modifiedAt == text.modifiedAt)
    }

    @Test func sendingAnUnsentDraftDropsItsSetupAndRemovesItFromTheList() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChat(UUID())))
        store.setText("Send me", in: draft)
        store.setNewChatSetup(setup(folder: "/repo"), in: draft)
        #expect(await store.flush())
        store.submitted(try #require(store.beginSending(draft)), conversationID: draft.id)
        #expect(draft.newChat == nil)
        #expect(await store.flush())
        #expect(try await storedDrafts(in: directory).isEmpty)
        store.setNewChatSetup(setup(folder: "/elsewhere"), in: draft)
        #expect(draft.newChat == nil)
    }

    @Test func discardHidesAtOnceUndoKeepsTheDraftAndTheDeadlineDeletesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let id = UUID()
        let draft = try #require(await store.draft(for: .newChat(id)))
        store.setText("Maybe later", in: draft)
        #expect(await store.flush())
        #expect(await waitUntil { store.listedUnsentDrafts.map(\.id) == [id] })
        var released: [ComposerDraft] = []

        store.discardUnsentDraft(id, after: .seconds(60)) { released.append($0) }
        #expect(store.listedUnsentDrafts.isEmpty)
        #expect(await ComposerDraftStore(directory: directory).draft(for: .newChat(id))?.composerText == "Maybe later")
        store.restoreUnsentDraft(id)
        #expect(store.listedUnsentDrafts.map(\.id) == [id])

        store.discardUnsentDraft(id, after: .zero) { released.append($0) }
        #expect(await waitUntil { store.unsentDrafts.isEmpty && !store.isDiscarding(id) })
        #expect(released.count == 1 && released.first === draft)
        #expect(try await storedDrafts(in: directory).isEmpty)
        #expect(await store.draft(for: .newChat(id))?.composerText == "")
    }

    @Test func aMainBuildStoreOpensWithItsNewChatDraftsKeyedAndBlankOnesRemoved() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windowKey = UUID()
        let legacy: UUID
        do {
            let context = try MainBuildDraftStore.context(in: directory)
            let phone = MainBuildDraftStore.ComposerDraft(destination: "new-chat", text: "Dictated for fifteen minutes",
                                                          attachments: [file()])
            let window = MainBuildDraftStore.ComposerDraft(destination: ComposerDraftStore.Destination.newChat(windowKey).key,
                                                           text: "Second window idea", attachments: [])
            let blank = MainBuildDraftStore.ComposerDraft(destination: ComposerDraftStore.Destination.newChat(UUID()).key,
                                                          text: " ", attachments: [.text("  \n")])
            let reply = MainBuildDraftStore.ComposerDraft(destination: ComposerDraftStore.Destination.thread("thread").key,
                                                          text: "Reply in progress", attachments: [])
            for draft in [phone, window, blank, reply] { context.insert(draft) }
            try context.save()
            legacy = phone.id
        }

        let summaries = Dictionary(uniqueKeysWithValues: try await storedDrafts(in: directory).map { ($0.id, $0) })
        #expect(Set(summaries.keys) == [legacy, windowKey])
        #expect(summaries[legacy]?.title == "Dictated for fifteen minutes")
        #expect(summaries[windowKey]?.title == "Second window idea")
        #expect(summaries[legacy]?.setup == nil)
        #expect(summaries[legacy]?.modifiedAt == nil)
        #expect(try storedDestinations(in: directory).sorted() == [
            ComposerDraftStore.Destination.newChat(legacy).key, ComposerDraftStore.Destination.newChat(windowKey).key,
            ComposerDraftStore.Destination.thread("thread").key
        ].sorted())
        let restored = try #require(await ComposerDraftStore(directory: directory).draft(for: .newChat(legacy)))
        #expect(restored.id == legacy)
        #expect(restored.attachments.count == 1)
    }

    @Test func bindingAnUnsentDraftToItsThreadDropsItsSetupAndListing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let id = UUID()
        let draft = try #require(await store.draft(for: .newChat(id)))
        store.setText("Becomes a reply draft", in: draft)
        store.setNewChatSetup(setup(folder: "/repo"), in: draft)
        #expect(await store.flush())
        #expect(await waitUntil { store.unsentDrafts.map(\.id) == [id] })

        await store.bind(draft, to: "thread")
        #expect(draft.newChat == nil)
        #expect(await waitUntil { store.unsentDrafts.isEmpty })
        #expect(try storedDestinations(in: directory) == [ComposerDraftStore.Destination.thread("thread").key])
    }

    @Test func lateWritesToADiscardedDraftNeitherReviveItNorBlockLaterSaves() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let id = UUID()
        let discarded = try #require(await store.draft(for: .newChat(id)))
        store.setText("Discard me", in: discarded)
        #expect(await store.flush())
        store.discardUnsentDraft(id, after: .zero) { _ in }
        #expect(await waitUntil { !store.isDiscarding(id) })

        store.setAttachments([file()], in: discarded)
        try await store.appendDictation("Late transcript", recordingID: UUID(), to: discarded)
        store.setNewChatSetup(setup(folder: "/late"), in: discarded)
        let keptID = UUID()
        store.setText("Still saves", in: try #require(await store.draft(for: .newChat(keptID))))
        #expect(await store.flush())
        #expect(store.errorMessage == nil)
        #expect(try storedDestinations(in: directory) == [ComposerDraftStore.Destination.newChat(keptID).key])
    }

    @Test func aDictationReceiptSavesWhenItsDraftWasClearedInTheSameBatch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChat(UUID())))
        let recordingID = UUID()
        try await store.appendDictation("Spoken then deleted", recordingID: recordingID, to: draft)
        store.setText("", in: draft)
        #expect(await store.flush())
        #expect(store.errorMessage == nil)
        #expect(try await store.hasSavedReceipt(for: recordingID))
        #expect(try await storedDrafts(in: directory).isEmpty)
    }

    @Test func rowsMatchTheQueryAndListNewestFirstAcrossTargets() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let mini = ExecutionTarget(hostID: UUID())
        let macBook = ExecutionTarget(hostID: UUID())
        let older = summary("Fix the drawer", folder: "/Users/developer/RemoteCoder", model: "gpt-6.1-sol", at: now - 7200)
        let newer = summary("Plan the release", folder: nil, model: ClaudeModelCatalog.fableModelID, at: now - 60)
        let unknownTime = summary("Imported", folder: "/tmp", model: nil, at: nil)
        let inputs = [
            UnsentDraftRow.TargetInput(target: mini, hostName: "Mini", remoteHomePath: "/Users/developer", drafts: [older, unknownTime]),
            UnsentDraftRow.TargetInput(target: macBook, hostName: "MacBook", remoteHomePath: nil, drafts: [newer])
        ]
        let selected = UnsentDraftAddress(target: mini, draftID: older.id)

        let rows = UnsentDraftRow.rows(from: inputs, selected: selected, showsHostLabels: true, query: "",
                                       condensedPaths: CondensedPathCache(), now: now)
        #expect(rows.map(\.title) == ["Plan the release", "Fix the drawer", "Imported"])
        #expect(rows.map(\.isSelected) == [false, true, false])
        #expect(rows.map(\.provider) == [.claude, .codex, nil])
        #expect(rows.map(\.ageLabel) == ["1m", "2h", nil])
        #expect(rows[0].workingDirectory.isEmpty)
        #expect(rows[1].workingDirectory == "~/RemoteCoder")

        let filtered = UnsentDraftRow.rows(from: inputs, selected: nil, showsHostLabels: true, query: "mini drawer",
                                           condensedPaths: CondensedPathCache(), now: now)
        #expect(filtered.map(\.address) == [selected])
    }

    private func storedDestinations(in directory: URL) throws -> [String] {
        let configuration = ModelConfiguration(url: directory.appending(path: "drafts.store"), cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: ComposerDraft.self, DictationReceipt.self, DraftImportReceipt.self,
                                                      configurations: configuration))
        return try context.fetch(FetchDescriptor<ComposerDraft>()).map(\.destination)
    }

    private func storedDrafts(in directory: URL) async throws -> [UnsentDraftSummary] {
        try await ComposerDraftPersistence.open(directory: directory).unsentDrafts()
    }

    private func setup(folder: String, model: String? = nil, reasoning: ReasoningSelection = .automatic,
                       fast: Bool? = nil) -> NewChatSetup {
        NewChatSetup(workingDirectory: folder, modelID: model, reasoning: reasoning, fastMode: fast)
    }

    private func summary(_ title: String, folder: String?, model: String?, at date: Date?) -> UnsentDraftSummary {
        UnsentDraftSummary(id: UUID(), title: title,
                           setup: NewChatSetup(workingDirectory: folder, modelID: model, reasoning: .automatic, fastMode: nil),
                           modifiedAt: date)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID())")
    }

    private func file() -> ComposerAttachment {
        .file(ComposerFileAttachment(id: UUID(), name: "photo.jpg", byteCount: 64,
            placement: .uploaded(UploadedFile(path: "/host/uploads/x/photo.jpg", bytes: 64, sha256: "ab"))))
    }
}

@MainActor
private extension ComposerDraft {
    var composerText: String? { document?.content.expandedText }
}
