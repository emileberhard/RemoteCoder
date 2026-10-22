import Foundation
import SwiftData
import Testing
@testable import RemoteCoderCore

@MainActor
struct ComposerDraftStoreTests {
    @Test func legacyTextAttachmentsRestoreExactWhitespaceAndUsefulPasteIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = ComposerAttachment.text(" \n\t ")
        let useful = ComposerAttachment.text(" useful pasted context\n")
        let legacy = try seedLegacyNewChat(in: directory) { draft in
            draft.text = "Before"
            draft.attachments = [blank, useful]
        }
        let expected = ComposerDocumentContent(runs: [.text("Before \n\t "),
            .paste(.init(id: useful.id, text: " useful pasted context\n"))])
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChat(legacy)))
        #expect(draft.id == legacy)
        #expect(draft.document?.content == expected)
        #expect(draft.attachments.isEmpty)
        #expect(await store.flush())
        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .newChat(legacy))?.document?.content == expected)
        #expect(reopened.errorMessage == nil)
    }


    @Test func quitBlocksInteractiveEditsButSavesAdmittedDictationAndCanReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("Original draft", in: draft)
        let reservation = try #require(store.reserveSubmission(of: draft))
        store.quiesce()
        store.setText("Late edit", in: draft)
        store.setAttachments([file()], in: draft)
        #expect(draft.composerText == "Original draft")
        #expect(draft.attachments.isEmpty)
        #expect(store.reserveSubmission(of: draft) == nil)
        let recording = UUID()
        try await store.appendDictation("Admitted dictation", recordingID: recording, to: draft)
        store.releaseSubmission(reservation)
        await store.drainSubmissions()
        #expect(await store.flush())
        #expect(try await store.hasSavedReceipt(for: recording))
        let cold = ComposerDraftStore(directory: directory)
        #expect(await cold.draft(for: .newChatFixture)?.composerText == "Original draft Admitted dictation")
        let conversationID = UUID()
        store.submitted(try #require(store.beginSending(draft)), conversationID: conversationID)
        #expect(store.document(for: draft).content.runs.isEmpty)
        #expect(store.applyTransfer(.init(runs: [.text("Admitted transfer")]), attachments: [],
            to: draft, expectedRevision: draft.revision))
        #expect(await store.flush())
        #expect(draft.composerText == "Admitted transfer")
        store.resume()
        store.setText("Keep Open edit", in: draft)
        #expect(await store.flush())
        let reopened = try #require(store.reserveSubmission(of: draft))
        store.releaseSubmission(reopened)
        #expect(await ComposerDraftStore(directory: directory).draft(for: .conversation(conversationID))?.composerText == "Keep Open edit")
    }

    @Test func aRejectedLateEditCannotPreventCleanStorageRetirement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("Durable text", in: draft)
        #expect(await store.flush())
        let document = store.document(for: draft)
        let storage = NSMutableAttributedString(attributedString: document.buffer)
        let token = try #require(document.mount(storage, editor: { request in
            request.complete(.failure(CancellationError()))
        }, isComposing: { false }, onRetire: { store.setText("Rejected late edit", in: draft) }))

        #expect(await store.retire())
        #expect(await store.retire())
        document.unmount(token)
        #expect(document.content.expandedText == "Durable text")
        let replacement = ComposerDraftStore(directory: directory)
        defer { await replacement.retire() }
        #expect(await replacement.draft(for: .newChatFixture)?.composerText == "Durable text")
    }

    @Test func retirementJoinsAnAcceptedComposingDictationAndItsReceipt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        defer { await store.retire() }
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("before", in: draft)
        let document = store.document(for: draft)
        let storage = NSMutableAttributedString(attributedString: document.buffer)
        let (queued, continuation) = AsyncStream<Void>.makeStream()
        let token = try #require(document.mount(storage, editor: { request in
            request.complete(.failure(CancellationError()))
        }, isComposing: { continuation.yield(()); return true }, onRetire: {}))
        let recordingID = UUID()
        let dictation = Task { try await store.appendDictation("accepted", recordingID: recordingID, to: draft) }
        var iterator = queued.makeAsyncIterator()
        _ = await iterator.next()

        #expect(await store.retire())
        do { try await dictation.value }
        catch { Issue.record("An accepted dictation must commit its receipt before retirement: \(error)") }
        document.unmount(token)
        let replacement = ComposerDraftStore(directory: directory)
        defer { await replacement.retire() }
        #expect(await replacement.draft(for: .newChatFixture)?.composerText == "before accepted")
        #expect(try await replacement.hasSavedReceipt(for: recordingID))
    }

    @Test func retainedDocumentRejectsEditsBeforeMutationAfterRetirement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("Before retirement", in: draft)
        let document = store.document(for: draft)
        #expect(await store.retire())

        await #expect(throws: ComposerDraftPersistence.Failure.self) {
            try await document.apply(.replaceAll(.init(runs: [.text("Rejected edit")])))
        }
        #expect(document.content.expandedText == "Before retirement")
    }

    @Test func retirementSavesAnAcceptedEditQueuedDuringComposition() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("Before composition", in: draft)
        #expect(await store.flush())
        let document = store.document(for: draft)
        let storage = NSMutableAttributedString(attributedString: document.buffer)
        var composing = true
        let token = try #require(document.mount(storage, editor: { request in
            guard let (range, replacement) = document.replacement(for: request.edit) else {
                request.complete(.success(())); return
            }
            let removed = storage.attributedSubstring(from: range).string
            let inserted = ComposerDocument.attributed(replacement)
            storage.replaceCharacters(in: range, with: inserted)
            document.changedCharacters(in: range, removed: removed, inserted: inserted.string)
            request.complete(.success(()))
        }, isComposing: { composing }, onRetire: {}))
        store.setText("Accepted while composing", in: draft)

        #expect(await store.retire())
        composing = false
        document.editorStateChanged()
        document.unmount(token)
        let replacement = ComposerDraftStore(directory: directory)
        defer { await replacement.retire() }

        #expect(await replacement.draft(for: .newChatFixture)?.composerText == "Accepted while composing")
    }

    @Test func failedRetirementRetainsDirtyTextAndReceiptsForRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("collision")))
        store.setText("Pending text", in: draft)
        let recordingID = UUID()
        try await store.appendDictation("and dictation", recordingID: recordingID, to: draft)
        let external = try await ComposerDraftPersistence.open(directory: directory)
        let conflictingID = UUID()
        _ = try await external.save([.init(id: conflictingID, destination: draft.destination, revision: 0,
            content: .init(runs: [.text("Other owner's draft")]), attachments: [], modifiedAt: nil, newChat: nil)], receipts: [:])

        #expect(await store.retire() == false)
        let saveError = try #require(store.errorMessage)
        store.setText("Rejected late edit", in: draft)
        #expect(store.errorMessage == saveError)
        _ = try await external.save([.init(id: conflictingID, destination: "thread:other-owner", revision: 1,
            content: .init(runs: [.text("Other owner's draft")]), attachments: [], modifiedAt: nil, newChat: nil)], receipts: [:])
        #expect(await store.retire())
        await external.retire()
        let replacement = ComposerDraftStore(directory: directory)
        defer { await replacement.retire() }

        #expect(await replacement.draft(for: .thread("collision"))?.composerText == "Pending text and dictation")
        #expect(try await replacement.hasSavedReceipt(for: recordingID))
    }

    @Test func retirementSavesPendingEditsAndRejectsLaterWritesWithoutReopeningStorage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        defer { await store.retire() }
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("Saved before retirement", in: draft)

        await store.retire()
        await store.retire()
        store.setText("Late edit", in: draft)
        #expect(draft.composerText == "Saved before retirement")
        #expect(await store.flush() == false)
        let recordingID = UUID()
        do {
            try await store.appendDictation("Late dictation", recordingID: recordingID, to: draft)
            Issue.record("Retired storage must reject dictation with its typed retired error")
        } catch ComposerDraftPersistence.Failure.retired {} catch {
            Issue.record("Expected retired storage, received \(error)")
        }
        let replacement = ComposerDraftStore(directory: directory)
        defer { await replacement.retire() }

        #expect(await replacement.draft(for: .newChatFixture)?.composerText == "Saved before retirement")
        #expect(try await !replacement.hasSavedReceipt(for: recordingID))
    }

    @Test func cachedPresentationStaysUnknownUntilAnOffMainLoadAndDurableSaveComplete() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        #expect(store.cachedDraft(for: .newChatFixture) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let draft = try #require(await store.draft(for: .newChatFixture))
        #expect(store.cachedDraft(for: .newChatFixture) === draft)
        store.setText("Retain this draft", in: draft)
        #expect(await store.flush())
        let reopened = ComposerDraftStore(directory: directory)
        #expect(reopened.cachedDraft(for: .newChatFixture) == nil)
        let restored = try #require(await reopened.draft(for: .newChatFixture))
        #expect(restored.id == draft.id)
        #expect(restored.composerText == "Retain this draft")
    }

    @Test func conversationsAndNewChatRestoreTextAndAttachmentsFromDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let newChat = try #require(await store.draft(for: .newChatFixture))
        let text = "An unfinished message\n\nwith whitespace  "
        store.setText(text, in: newChat)
        let attachments = [ComposerAttachment.text(String(repeating: "pasted context ", count: 100)), legacyImage(), file()]
        store.setAttachments(attachments, in: newChat)

        store.setText("Codex draft", in: try #require(await store.draft(for: .thread("codex-thread"))))
        store.setText("Claude draft", in: try #require(await store.draft(for: .thread("claude_thread"))))
        await store.flush()
        #expect(store.errorMessage == nil)

        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .newChatFixture)?.id == newChat.id)
        #expect(await reopened.draft(for: .newChatFixture)?.composerText == text + (attachments.first?.text ?? ""))
        #expect(await reopened.draft(for: .newChatFixture)?.attachments == Array(attachments.dropFirst()))
        #expect(await reopened.draft(for: .thread("codex-thread"))?.composerText == "Codex draft")
        #expect(await reopened.draft(for: .thread("claude_thread"))?.composerText == "Claude draft")
    }

    @Test func editingPastedTextPersistsInItsOriginalDraftAndCannotRestoreASentAttachment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let first = try #require(await store.draft(for: .thread("first")))
        let attachment = ComposerAttachment.text("original pasted text")
        store.setAttachments([attachment], in: first)
        let second = try #require(await store.draft(for: .thread("second")))
        store.setText("Keep this", in: second)
        let revision = first.revision
        store.updatePastedText("edited", attachmentID: attachment.id, in: first)
        #expect(first.revision > revision)
        await store.flush()
        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .thread("first"))?.document?.content.pasted.first?.text == "edited")
        #expect(second.composerText == "Keep this")
        #expect(second.attachments.isEmpty)
        store.submitted(try #require(store.beginSending(first)), conversationID: first.id)
        store.updatePastedText("late edit", attachmentID: attachment.id, in: first)
        #expect(first.attachments.isEmpty)
    }

    @Test func sendingNewChatSeparatesItsFollowupFromTheNextNewChat() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let original = try #require(await store.draft(for: .newChatFixture))
        store.setText("Send this", in: original)
        store.submitted(try #require(store.beginSending(original)), conversationID: original.id)
        #expect(original.document?.isEmpty == true)
        store.setText("A follow-up while the thread starts", in: original)

        let next = try #require(await store.draft(for: .newChatFixture))
        #expect(next.id != original.id)
        #expect(next.document?.isEmpty == true)
        store.setText("A separate new chat", in: next)

        await store.bind(original, to: "created-thread")
        #expect(await store.draft(for: .newChatFixture) === next)
        await store.flush()

        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .newChatFixture)?.composerText == "A separate new chat")
        #expect(await reopened.draft(for: .thread("created-thread"))?.composerText == "A follow-up while the thread starts")
    }

    @Test func newChatDraftsKeepIndependentKeysUntilEachIsSent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let firstKey = ComposerDraftStore.Destination.newChat(UUID())
        let secondKey = ComposerDraftStore.Destination.newChat(UUID())
        let first = try #require(await store.draft(for: firstKey))
        let second = try #require(await store.draft(for: secondKey))
        let third = try #require(await store.draft(for: .newChatFixture))
        #expect(Set([first.id, second.id, third.id]).count == 3)
        store.setText("First draft", in: first)
        store.setText("Second draft", in: second)

        store.submitted(try #require(store.beginSending(first)), conversationID: first.id)
        #expect(first.document?.isEmpty == true)
        #expect(second.composerText == "Second draft")
        #expect(await store.draft(for: secondKey) === second)
        #expect(await store.draft(for: firstKey) !== first)
        #expect(await store.draft(for: firstKey)?.composerText == "")

        store.submitted(try #require(store.beginSending(second)), conversationID: second.id)
        #expect(first.destination == ComposerDraftStore.Destination.conversation(first.id).key)
        #expect(second.destination == ComposerDraftStore.Destination.conversation(second.id).key)
        #expect(await store.draft(for: .newChatFixture) === third)
    }

    @Test func editsWhileAMessageIsOutgoingSurviveItsSubmission() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let first = try #require(await store.draft(for: .thread("first")))
        store.setText("Submitted text", in: first)
        let outgoing = try #require(store.beginSending(first))
        #expect(first.composerText == "")
        store.setText("Newer text", in: first)
        let second = try #require(await store.draft(for: .thread("second")))
        store.setText("Keep this too", in: second)

        store.submitted(outgoing, conversationID: UUID())
        #expect(first.composerText == "Newer text")
        #expect(second.composerText == "Keep this too")
        // A late dictation or photo import holds the originating draft.
        store.appendText("late dictation", to: first)
        store.setAttachments([file()], in: first)
        await store.flush()
        #expect(second.composerText == "Keep this too")
        #expect(second.attachments.isEmpty)
        #expect(await store.draft(for: .thread("first")) === first)
        #expect(first.composerText == "Newer text late dictation")
        #expect(first.attachments.count == 1)
    }

    @Test func anOutgoingMessageStaysSavedInItsDraftUntilTheTranscriptHoldsIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("thread")))
        store.setText("Send me", in: draft)
        store.setAttachments([file()], in: draft)
        let outgoing = try #require(store.beginSending(draft))
        #expect(draft.composerText == "")
        #expect(draft.attachments.isEmpty)
        #expect(store.hasContent(draft))
        store.setText("Next thought", in: draft)
        #expect(await store.flush())
        let crashed = try #require(await ComposerDraftStore(directory: directory).draft(for: .thread("thread")))
        #expect(crashed.composerText == "Send me\nNext thought")
        #expect(crashed.attachments.count == 1)

        store.submitted(outgoing, conversationID: UUID())
        #expect(await store.flush())
        let reopened = try #require(await ComposerDraftStore(directory: directory).draft(for: .thread("thread")))
        #expect(reopened.composerText == "Next thought")
        #expect(reopened.attachments.isEmpty)
    }

    @Test func aMessageThatCouldNotBeSavedReturnsAheadOfNewText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("thread")))
        let attachment = file()
        store.setText("Send me", in: draft)
        store.setAttachments([attachment], in: draft)
        let outgoing = try #require(store.beginSending(draft))
        store.setText("Typed after", in: draft)
        store.returnToComposer(outgoing)
        #expect(draft.composerText == "Send me\nTyped after")
        #expect(draft.attachments == [attachment])
        #expect(await store.flush())
        #expect(await ComposerDraftStore(directory: directory).draft(for: .thread("thread"))?.composerText == "Send me\nTyped after")
    }

    @Test func messagesThatCouldNotBeSavedReturnInTheOrderTheyWereSent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("thread")))
        let firstFile = file()
        let secondFile = file()
        store.setText("First", in: draft)
        store.setAttachments([firstFile], in: draft)
        let first = try #require(store.beginSending(draft))
        store.setText("Second", in: draft)
        store.setAttachments([secondFile], in: draft)
        let second = try #require(store.beginSending(draft))
        store.setText("Typed after", in: draft)
        store.returnToComposer(second)
        #expect(draft.composerText == "Typed after")
        store.returnToComposer(first)
        #expect(draft.composerText == "First\nSecond\nTyped after")
        #expect(draft.attachments == [firstFile, secondFile])

        let other = try #require(await store.draft(for: .thread("other")))
        store.setText("Saved", in: other)
        let saved = try #require(store.beginSending(other))
        store.setText("Lost", in: other)
        let lost = try #require(store.beginSending(other))
        store.returnToComposer(lost)
        #expect(other.composerText == "")
        store.submitted(saved, conversationID: UUID())
        #expect(other.composerText == "Lost")
    }

    @Test func aReturnedMessageWaitsForCompositionAndKeepsTheCommittedText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("thread")))
        store.setText("Send me", in: draft)
        let outgoing = try #require(store.beginSending(draft))
        let document = store.document(for: draft)
        let storage = NSMutableAttributedString(attributedString: document.buffer)
        var composing = true
        let token = try #require(mountApplyingEditor(document, storage: storage) { composing })

        store.returnToComposer(outgoing)
        #expect(store.hasContent(draft))
        #expect(await store.flush())
        #expect(await ComposerDraftStore(directory: directory).draft(for: .thread("thread"))?.composerText == "Send me")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Composed")
        document.changedCharacters(in: NSRange(location: 0, length: 0), removed: "", inserted: "Composed")
        composing = false
        document.editorStateChanged()
        #expect(document.content.expandedText == "Send me\nComposed")
        #expect(await store.flush())
        #expect(await ComposerDraftStore(directory: directory).draft(for: .thread("thread"))?.composerText == "Send me\nComposed")
        document.unmount(token)
    }

    @Test func aRestoreTheComposerRefusesReturnsWithTheNextFailedMessage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("thread")))
        store.setText("First", in: draft)
        let first = try #require(store.beginSending(draft))
        let document = store.document(for: draft)
        let storage = NSMutableAttributedString(attributedString: document.buffer)
        var composing = true
        let token = try #require(mountApplyingEditor(document, storage: storage) { composing })
        for _ in 0..<16 { document.edit(.append(.init(runs: [.text("x")]))) }

        store.returnToComposer(first)
        #expect(store.hasContent(draft))
        composing = false
        document.editorStateChanged()
        store.setText("Second", in: draft)
        let second = try #require(store.beginSending(draft))
        store.returnToComposer(second)
        #expect(draft.composerText == "First\nSecond")
        document.unmount(token)
    }

    @Test func clearedDraftStaysEmptyAfterRelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("thread")))
        store.setText("Sent", in: draft)
        store.setAttachments([file()], in: draft)
        store.submitted(try #require(store.beginSending(draft)), conversationID: UUID())
        #expect(!store.hasContent(draft))
        #expect(await store.flush())
        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .thread("thread"))?.composerText == "")
        #expect(await reopened.draft(for: .thread("thread"))?.attachments.isEmpty == true)
    }

    @Test func identicalThreadIDsInDifferentDirectoriesRestoreIndependentDrafts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = [root.appending(path: "first-host"), root.appending(path: "second-host")]
        for (directory, text) in zip(directories, ["First host", "Second host"]) {
            let store = ComposerDraftStore(directory: directory)
            store.setText(text, in: try #require(await store.draft(for: .thread("shared"))))
            #expect(await store.flush())
        }
        let reopened = directories.map { ComposerDraftStore(directory: $0) }
        var texts: [String?] = []
        for store in reopened { texts.append(await store.draft(for: .thread("shared"))?.text) }
        #expect(texts == ["First host", "Second host"])
    }

    @Test func openingFailureIsVisibleAndRetryCanRecover() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory)
        let store = ComposerDraftStore(directory: directory)
        #expect(await store.draft(for: .newChatFixture) == nil)
        #expect(store.destinationError(for: .newChatFixture) != nil)
        try FileManager.default.removeItem(at: directory)
        #expect(await store.draft(for: .newChatFixture) != nil)
        #expect(store.destinationError(for: .newChatFixture) == nil)
    }

    @Test func aSuccessfulUnrelatedLoadCannotHideAFailedNavigationSave() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .thread("first")))
        let external = try await ComposerDraftPersistence.open(directory: directory)
        _ = try await external.save([.init(id: UUID(), destination: draft.destination, revision: 0,
            content: .init(runs: [.text("Occupied elsewhere")]), attachments: [], modifiedAt: nil, newChat: nil)], receipts: [:])
        store.setText("Keep my dirty edits", in: draft)
        store.requestFlush()
        let unrelated = try #require(await store.draft(for: .thread("unrelated")))
        #expect(unrelated.document?.isEmpty == true)
        #expect(store.errorMessage?.contains("could not be saved") == true)
        #expect(store.destinationError(for: .thread("unrelated")) == nil)
        #expect(draft.composerText == "Keep my dirty edits")
        await store.bind(draft, to: "recovered")
        #expect(await store.flush())
        #expect(store.errorMessage == nil)
        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .thread("recovered"))?.composerText == "Keep my dirty edits")
    }

    @Test func admissionIsScopedToADraftRevisionAndFailureReleasesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("First revision", in: draft)
        let first = try #require(store.reserveSubmission(of: draft))
        #expect(store.reserveSubmission(of: draft) == nil)
        store.setText("A deliberate new revision", in: draft)
        let second = try #require(store.reserveSubmission(of: draft))
        store.releaseSubmission(first)
        #expect(store.reserveSubmission(of: draft) == nil)
        store.releaseSubmission(second)
        #expect(store.reserveSubmission(of: draft) != nil)
    }

    @Test func retirementDrainJoinsAnAdmittedTransferBeforeAReplacementReadsTheStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("Before transfer", in: draft)
        #expect(await store.flush())
        let reservation = try #require(store.reserveSubmission(of: draft))
        let (saving, admitted) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (saved, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let transfer = Task {
            defer { store.releaseSubmission(reservation) }
            admitted.yield(())
            for await _ in saved { break }
            store.applyTransfer(.init(runs: []), attachments: [], to: draft, expectedRevision: draft.revision)
            await store.flush()
        }
        var starts = saving.makeAsyncIterator()
        _ = await starts.next()
        var retired = false
        let (draining, started) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let retirement = Task {
            started.yield(())
            await store.drainSubmissions()
            retired = true
        }
        var drains = draining.makeAsyncIterator()
        _ = await drains.next()
        #expect(!retired)
        release.yield(())
        await transfer.value
        await retirement.value
        #expect(retired)
        let replacement = ComposerDraftStore(directory: directory)
        let restored = try #require(await replacement.draft(for: .newChatFixture))
        replacement.setText("New owner typing", in: restored)
        #expect(await replacement.flush())
        #expect(await ComposerDraftStore(directory: directory).draft(for: .newChatFixture)?.composerText == "New owner typing")
    }

    @Test func dirtyLiveDraftsBeyondTheCacheLimitSaveInBoundedBatchesWithoutDroppingData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        var live: [ComposerDraft] = []
        for index in 0..<65 {
            live.append(try #require(await store.draft(for: .thread("thread-\(index)"))))
            #expect(await store.flush())
        }
        for (index, draft) in live.enumerated() { store.setText("Latest \(index)", in: draft) }
        let recording = UUID()
        let last = try #require(live.last)
        try await store.appendDictation("dictated", recordingID: recording, to: last)
        #expect(await store.flush())
        let reopened = ComposerDraftStore(directory: directory)
        for index in 0..<65 {
            let expected = index == 64 ? "Latest 64 dictated" : "Latest \(index)"
            #expect(await reopened.draft(for: .thread("thread-\(index)"))?.composerText == expected)
        }
        #expect(try await reopened.hasSavedReceipt(for: recording))
    }

    @Test func aReceiptCannotCommitAheadOfItsDraftRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try await ComposerDraftPersistence.open(directory: directory)
        let id = UUID()
        let recording = UUID()
        let receipt = ComposerDraftReceipt(draftID: id, requiredRevision: 1, receivedAt: .now)
        await #expect(throws: ComposerDraftPersistence.Failure.self) {
            try await persistence.save([], receipts: [recording: receipt])
        }
        #expect(try await !persistence.hasSavedReceipt(recording))
        _ = try await persistence.save([.init(id: id, destination: "thread:dictation", revision: 1,
            content: .init(runs: [.text("Received text")]), attachments: [], modifiedAt: nil, newChat: nil)], receipts: [recording: receipt])
        #expect(try await persistence.hasSavedReceipt(recording))
        #expect(try await persistence.load(destination: "thread:dictation")?.text == "Received text")
    }

    @Test func applyingTheSameRecordingTwiceInsertsItsTextOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        let recordingID = UUID()
        try await store.appendDictation("Dictated once", recordingID: recordingID, to: draft)
        try await store.appendDictation("Dictated once", recordingID: recordingID, to: draft)
        #expect(try await !store.hasSavedReceipt(for: recordingID))
        #expect(await store.flush())
        #expect(draft.composerText == "Dictated once")
        #expect(try await store.hasSavedReceipt(for: recordingID))

        let reopened = ComposerDraftStore(directory: directory)
        let restored = try #require(await reopened.draft(for: .newChatFixture))
        #expect(restored.composerText == "Dictated once")
        #expect(try await reopened.hasSavedReceipt(for: recordingID))
        try await reopened.appendDictation("Dictated once", recordingID: recordingID, to: restored)
        #expect(await reopened.flush())
        #expect(restored.composerText == "Dictated once")
    }

    @Test func receiptsAreRemovedOnlyOnceTheyAreOlderThanTheCutoff() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        let expired = UUID()
        let recent = UUID()
        try await store.appendDictation("Earlier", recordingID: expired, to: draft)
        try await Task.sleep(for: .milliseconds(20))
        let cutoff = Date.now
        try await Task.sleep(for: .milliseconds(20))
        try await store.appendDictation("later", recordingID: recent, to: draft)
        #expect(await store.flush())

        try await store.removeReceipts(receivedBefore: cutoff)

        let reopened = ComposerDraftStore(directory: directory)
        #expect(await reopened.draft(for: .newChatFixture)?.composerText == "Earlier later")
        #expect(try await !reopened.hasSavedReceipt(for: expired))
        #expect(try await reopened.hasSavedReceipt(for: recent))
    }

    @Test func draftsSavedBeforeDictationReceiptsSurviveTheSchemaChange() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try seedLegacyNewChat(in: directory) { $0.text = "Written by the previous build" }

        let store = ComposerDraftStore(directory: directory)
        #expect(store.errorMessage == nil)
        let draft = try #require(await store.draft(for: .newChat(legacy)))
        #expect(draft.composerText == "Written by the previous build")
        let recordingID = UUID()
        try await store.appendDictation("and dictated after it", recordingID: recordingID, to: draft)
        #expect(await store.flush())
        #expect(try await store.hasSavedReceipt(for: recordingID))
    }

    private func seedLegacyNewChat(in directory: URL, _ fill: (ComposerDraft) -> Void) throws -> UUID {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appending(path: "drafts.store"), cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: ComposerDraft.self, configurations: configuration))
        let draft = ComposerDraft(destination: "new-chat")
        fill(draft)
        context.insert(draft)
        try context.save()
        return draft.id
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "composer-drafts-\(UUID())")
    }

    private func mountApplyingEditor(_ document: ComposerDocument, storage: NSMutableAttributedString,
                                     isComposing: @escaping () -> Bool) -> UUID? {
        document.mount(storage, editor: { request in
            if let (range, content) = document.replacement(for: request.edit) {
                let removed = storage.attributedSubstring(from: range).string
                let inserted = ComposerDocument.attributed(content)
                storage.replaceCharacters(in: range, with: inserted)
                document.changedCharacters(in: range, removed: removed, inserted: inserted.string)
            }
            request.complete(.success(()))
        }, isComposing: isComposing, onRetire: {})
    }

    private func file() -> ComposerAttachment {
        .file(ComposerFileAttachment(id: UUID(), name: "Q3 report.pdf", byteCount: 4096,
            placement: .uploaded(UploadedFile(path: "/host/uploads/x/Q3-report.pdf", bytes: 4096, sha256: "ab"))))
    }

    private func legacyImage() -> ComposerAttachment {
        let image = CodexImageAttachment(id: UUID(), data: Data(repeating: 42, count: 200_000), format: .jpeg,
            pixelSize: CodexImagePixelSize(width: 320, height: 200))
        return ComposerAttachment(id: image.id, content: .legacyImage(image))
    }
}

@MainActor
private extension ComposerDraft {
    var composerText: String? { document?.content.expandedText }
}
