import Foundation
import Testing
@testable import RemoteCoder

/// The workspace owns one chat model per host. These tests cover what host
/// switching must not disturb: model identity, drafts and per-host addresses.
/// Nothing here bootstraps a model, so no gateway traffic is started.
@MainActor
struct ChatWorkspaceModelTests {
    @Test(.timeLimit(.minutes(1))) func retirementRejectsAListResponseOwnedByTheDrawerBeforeSocketTeardown() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadList(); await fixture.cleanUp(); await gateway.stop() }
        let screen = try #require(fixture.workspace.selectedScreen)
        let kept = try fixture.thread("kept", updatedAt: 1)
        let late = try fixture.thread("late", updatedAt: 2)
        let store = ConversationHeaderStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
        await store.save(snapshot: .init(threads: [kept], lastSuccessfulRefreshAt: nil, revision: 1))
        _ = await screen.target.conversationList.knownThread(id: kept.id)
        try await gateway.setListedThreads([late])
        await gateway.holdThreadList()
        let loading = Task { await fixture.workspace.loadOlderHistory(on: screen.executionTarget, in: fixture.workspace.keyWindow) }
        await gateway.waitForHeldThreadList()
        screen.target.beginRetirement()
        #expect(!loading.isCancelled)
        #expect(!screen.target.conversationList.isLoadingOlder)
        #expect(!screen.target.conversationList.canLoadOlder(query: ""))
        await gateway.releaseHeldThreadList()
        await loading.value
        #expect(screen.target.conversationList.threads == [kept])
        #expect(!screen.target.conversationList.isLoadingOlder)
        let reloaded = await ConversationHeaderStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage).load()
        #expect(reloaded.threads == [kept])
        #expect(reloaded.revision == 1)
    }

    @Test(arguments: [false, true])
    func selectedHeadersAndKnownParentsSurviveAdmissionBeforeTranscriptLoading(_ hasParent: Bool) async throws {
        let gateway = try FakeGatewayServer(threadID: "selected")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        var selected = try fixture.thread("selected", updatedAt: 1)
        if hasParent { selected.nativeParentThreadID = "parent" }
        let parent = try fixture.thread("parent", updatedAt: 0)
        let newer = try (0..<(ConversationHeaderRetention.countLimit - 2)).map {
            try fixture.thread("recent-\($0)", updatedAt: Int64($0 + 2))
        }
        let store = ConversationHeaderStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
        await store.save(snapshot: .init(threads: newer + [selected, parent], lastSuccessfulRefreshAt: nil, revision: 1))
        let screen = try #require(fixture.workspace.selectedScreen)
        _ = await screen.target.conversationList.knownThread(id: selected.id)
        screen.resumeConversation(selected)
        await gateway.waitForHeldThreadRead()
        for index in 0..<2 {
            await screen.target.conversationList.record(try fixture.thread("incoming-\(index)", updatedAt: Int64(2_000 + index)))
        }
        #expect(screen.loadingTranscriptID == selected.id)
        #expect(screen.target.conversationList.header(id: selected.id) != nil)
        #expect((screen.target.conversationList.header(id: parent.id) != nil) == hasParent)
        #expect(screen.target.conversationList.threads.count == ConversationHeaderRetention.countLimit)
    }

    @Test func failedDraftRetirementRetainsItsOwnerAndLeavesOtherNewChatsAvailable() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.screen(for: fixture.mini.id))
        try #require(await screen.prepareDraft())
        try #require(await screen.target.drafts.flush())
        let directory = fixture.temporaryStorage.storage.directory(for: .target(hostID: fixture.mini.id)).appending(path: "drafts")
        let draft = try #require(await screen.target.drafts.draft(for: screen.newChatDestination))
        let recordingID = UUID()
        let conflictingID = UUID()
        try await writeConflictingDraft(id: conflictingID, destination: draft.destination, directory: directory)
        screen.input = "Recover this draft"
        try await screen.target.drafts.appendDictation("and dictation", recordingID: recordingID, to: draft)
        var changed = fixture.mini
        changed.port = 3
        #expect(workspace.settings.upsert(changed))
        workspace.reconcileHosts()

        #expect(await workspace.finishHostChanges() == false)
        #expect(workspace.model(for: fixture.mini.id) == nil)
        #expect(workspace.keyWindow.selectedTarget == screen.executionTarget)
        let failure = try #require(workspace.draftRetirementFailure(for: screen.executionTarget))
        #expect(failure.target == screen.executionTarget)
        #expect(!failure.message.isEmpty)
        workspace.reconcileHosts()
        #expect(workspace.model(for: fixture.mini.id) == nil)
        let next = try #require(workspace.startNewConversation(onHostID: fixture.book.id))
        #expect(await next.prepareDraft())
        next.input = "An independent new chat"
        #expect(await next.target.drafts.flush())

        try await writeConflictingDraft(id: conflictingID, destination: "thread:other-owner", directory: directory)
        workspace.retryDraftRetirement(failure.target)
        #expect(workspace.draftRetirementFailure(for: failure.target)?.target == failure.target)
        #expect(workspace.isRetryingDraftRetirement(failure.target))
        #expect(await workspace.finishHostChanges())
        #expect(workspace.draftRetirementFailure(for: screen.executionTarget) == nil)
        let replacement = try #require(workspace.model(for: fixture.mini.id))
        #expect(replacement !== screen.target)
        #expect(await replacement.drafts.draft(for: screen.newChatDestination)?.document?.content.expandedText == "Recover this draft and dictation")
        #expect(try await replacement.drafts.hasSavedReceipt(for: recordingID))
        #expect(next.input == "An independent new chat")
    }

    @Test func changedNewChatDefaultReachesHiddenHost() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let visible = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let hidden = try #require(fixture.workspace.screen(for: fixture.book.id))
        #expect(!hidden.target.isVisible)

        fixture.defaults.set(ReasoningSelection.automatic.id, forKey: NewChatDefaults.reasoningDefaultKey)
        fixture.workspace.refreshNewChatDefaults()

        #expect(visible.reasoningSelection == .automatic)
        #expect(hidden.reasoningSelection == .automatic)
    }

    @Test(.timeLimit(.minutes(1))) func staleQuestionCannotDispatchOrConsumeTheCurrentComposerDraft() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { fixture.workspace.teardown(); await fixture.cleanUp(); await gateway.stop() }
        let model = try #require(fixture.workspace.selectedScreen)
        let attachment = ComposerAttachment.text("Unfinished attachment")
        #expect(await model.prepareDraft())
        model.input = "Still writing this message"
        model.composerAttachments = [attachment]
        let address = QuestionAddress(conversation: .init(hostID: model.hostID, threadID: "stale-thread"), itemID: "question-1")
        let entry = QuestionReplyEnvelope.Entry(itemID: address.itemID, index: 0,
            reply: .init(question: "Which approach?", answer: "Patch"))
        await #expect(throws: (any Error).self) {
            try await model.answerQuestion(address, entries: [entry], version: .init(epoch: "fixture-epoch", revision: 1))
        }
        #expect(model.composerDocument?.content == ComposerDocumentContent(runs: [.text("Still writing this message"),
            .paste(.init(id: attachment.id, text: "Unfinished attachment"))]))
        #expect(model.composerAttachments.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(await gateway.turnStarts.isEmpty)
        #expect(await gateway.steers.isEmpty)
    }

    @Test func sendingTheComposerClearsItsDraftAndReleasesTheNewChatSlot() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        let submittedConversationID = model.currentConversationID
        model.input = "Send this message"
        model.composerAttachments = [.text("Send this attachment")]

        #expect(await model.send())

        #expect(model.input.isEmpty)
        #expect(model.composerAttachments.isEmpty)
        model.startNewConversation()
        #expect(await model.prepareDraft())
        #expect(model.currentConversationID != submittedConversationID)
        #expect(model.input.isEmpty)
    }

    @Test func switchingConversationsRestoresTheirDraftsAndNewChatKeepsTheUnsentOne() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        let newChatID = model.currentConversationID
        let unsent = model.newChatDraftID
        model.input = "Unsent new chat"
        let codex = try fixture.thread("draft-codex", updatedAt: 1)
        let claude = try fixture.thread("claude_draft", updatedAt: 2)

        model.resumeConversation(codex)
        #expect(model.input.isEmpty)
        #expect(await model.prepareDraft())
        model.input = "Codex instructions"
        model.resumeConversation(claude)
        #expect(model.input.isEmpty)
        #expect(await model.prepareDraft())
        model.input = "Claude instructions"
        model.startNewConversation()
        #expect(await model.prepareDraft())
        #expect(model.input.isEmpty)
        #expect(model.newChatDraftID != unsent)
        let fresh = model.newChatDraftID
        model.startNewConversation()
        #expect(model.newChatDraftID == fresh)
        model.openUnsentDraft(unsent)
        #expect(await model.prepareDraft())
        #expect(model.input == "Unsent new chat")
        #expect(model.currentConversationID == newChatID)
        model.resumeConversation(codex)
        #expect(model.input == "Codex instructions")
        model.resumeConversation(claude)
        #expect(model.input == "Claude instructions")
    }

    @Test func switchingWithinAHostFinishesDictationIntoItsOriginalConversation() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget,
                                           transcriber: StubTranscriber(text: "dictated for new chat"),
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)
        #expect(await model.prepareDraft())
        let unsent = model.newChatDraftID
        model.micTapStart()
        await model.micTapStartAsync()
        model.resumeConversation(try fixture.thread("other", updatedAt: 1))
        #expect(await model.prepareDraft())
        model.input = "Other draft"
        #expect(await waitUntil { !model.target.voice.isTranscribing })
        #expect(model.input == "Other draft")
        model.openUnsentDraft(unsent)
        #expect(await model.prepareDraft())
        #expect(model.input == "dictated for new chat")
    }

    @Test func eachUnsentDraftReopensWithItsOwnFolderAndSettings() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let luna = try CodexModelFixtures.option(CodexModelFixtures.lunaID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        #expect(await model.prepareDraft())
        let first = model.newChatDraftID
        model.input = "Luna draft"
        model.selectModel(luna, for: nil)
        model.selectReasoning(.effort(.medium), for: nil)
        model.selectWorkingDirectory("/repo/luna")
        #expect(model.newChatDraftID == first)
        model.startNewConversation()
        #expect(await model.prepareDraft())
        let second = model.newChatDraftID
        model.input = "Astra draft"
        model.selectModel(astra, for: nil)
        model.selectReasoning(.effort(.high), for: nil)
        model.selectWorkingDirectory("/repo/astra")
        let edited = model.currentDraft?.modifiedAt

        model.openUnsentDraft(first)
        #expect(await model.prepareDraft())
        #expect(model.input == "Luna draft")
        #expect(model.selectedModel?.id == luna.id)
        #expect(model.reasoningSelection == .effort(.medium))
        #expect(model.workingDirectory == "/repo/luna")
        model.openUnsentDraft(second)
        #expect(await model.prepareDraft())
        #expect(model.selectedModel?.id == astra.id)
        #expect(model.reasoningSelection == .effort(.high))
        #expect(model.workingDirectory == "/repo/astra")
        #expect(model.currentDraft?.modifiedAt == edited)
        let stored = model.target.drafts.cachedDraft(for: .newChat(first))?.newChat
        #expect(stored?.modelID == luna.id)
        #expect(stored?.workingDirectory == "/repo/luna")
    }

    @Test func openingADraftInAnotherWindowMovesTheFirstWindowOffIt() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let first = workspace.attachWindow(opening: nil)
        let second = workspace.attachWindow(opening: .newChat(slot: UUID()))
        let original = try #require(first.selectedScreen)
        #expect(await original.prepareDraft())
        let address = UnsentDraftAddress(target: original.executionTarget, draftID: original.newChatDraftID)
        original.input = "Shared idea"
        let other = try #require(second.screen(for: address.target))

        #expect(workspace.openUnsentDraft(address, in: second) == .changed)
        #expect(await waitUntil { other.shownNewChatDraft == address.draftID })
        #expect(original.shownNewChatDraft != nil)
        #expect(original.newChatDraftID != address.draftID)
        #expect(await other.prepareDraft())
        #expect(other.input == "Shared idea")
        #expect(await original.prepareDraft())
        #expect(original.input.isEmpty)
    }

    @Test func discardingTheShownDraftMovesItsScreenAwayAndUndoCanReopenIt() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachWindow(opening: nil)
        let screen = try #require(window.selectedScreen)
        #expect(await screen.prepareDraft())
        let address = UnsentDraftAddress(target: screen.executionTarget, draftID: screen.newChatDraftID)
        screen.input = "Maybe later"

        #expect(workspace.discardUnsentDraft(address, undoWindow: .seconds(60)) == .discarded(wasShown: true))
        #expect(await waitUntil { screen.newChatDraftID != address.draftID })
        #expect(await screen.prepareDraft())
        #expect(screen.input.isEmpty)
        #expect(workspace.openUnsentDraft(address, in: window) == .unchanged)

        workspace.restoreUnsentDraft(address)
        #expect(workspace.openUnsentDraft(address, in: window) == .changed)
        #expect(await waitUntil { workspace.isShowingUnsentDraft(address, in: window) })
        #expect(await screen.prepareDraft())
        #expect(screen.input == "Maybe later")
    }

    @Test func aDraftCannotBeDiscardedWhileItsHostIsDictating() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget,
                                           transcriber: StubTranscriber(text: "still talking"),
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)
        #expect(await model.prepareDraft())
        model.input = "Dictating into this"
        let address = UnsentDraftAddress(target: model.executionTarget, draftID: model.newChatDraftID)
        model.micTapStart()
        await model.micTapStartAsync()

        #expect(fixture.workspace.discardUnsentDraft(address, undoWindow: .seconds(60)) == .refusedWhileDictating)
        #expect(!model.target.drafts.isDiscarding(address.draftID))
        #expect(model.newChatDraftID == address.draftID)
        model.micTapStopImmediate()
        await model.micTapStopAsync()
        #expect(await waitUntil { !model.target.voice.isTranscribing })
        #expect(model.input.hasSuffix("still talking"))
    }

    @Test func returningToAHostFindsTheSameModelWithItsDraftAndDirectory() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace

        let mini = try #require(workspace.screen(for: fixture.mini.id))
        let book = try #require(workspace.screen(for: fixture.book.id))
        #expect(mini !== book)

        #expect(await mini.prepareDraft())
        mini.input = "keep this draft"
        mini.workingDirectory = "/Users/developer/RemoteCoder"
        #expect(await book.prepareDraft())
        book.input = "other machine"
        book.workingDirectory = "/Users/developer/other"

        // Rapid switching: B, A, B, A.
        workspace.select(hostID: fixture.book.id)
        workspace.select(hostID: fixture.mini.id)
        workspace.select(hostID: fixture.book.id)
        workspace.select(hostID: fixture.mini.id)

        #expect(workspace.screen(for: fixture.mini.id) === mini)
        #expect(workspace.screen(for: fixture.book.id) === book)
        #expect(workspace.selectedScreen === mini)
        #expect(mini.input == "keep this draft")
        #expect(mini.workingDirectory == "/Users/developer/RemoteCoder")
        // The hidden host kept its own draft and directory untouched.
        #expect(book.input == "other machine")
        #expect(book.workingDirectory == "/Users/developer/other")
        #expect(mini.target.isVisible)
        #expect(book.target.isVisible == false)
    }

    @Test func aFavoriteOnAnotherHostOpensThatHostInTheFavoritedFolder() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let mini = try #require(workspace.screen(for: fixture.mini.id))
        let book = try #require(workspace.screen(for: fixture.book.id))
        #expect(await mini.prepareDraft())
        mini.workingDirectory = "/Users/developer/RemoteCoder"
        #expect(await book.prepareDraft())
        let hiddenDraft = book.newChatDraftID
        book.input = "other machine"
        book.selectWorkingDirectory("/Users/developer/RemoteCoder")
        let favorite = try #require(FavoriteFolder.list([
            .init(id: fixture.mini.id, name: "Mac Mini", paths: [], remoteHomePath: nil),
            .init(id: fixture.book.id, name: "MacBook", paths: ["/Users/developer/ExampleLibrary"], remoteHomePath: nil),
        ]).first)

        workspace.selectFavorite(favorite, from: mini, ifStillShowing: UUID())
        #expect(workspace.selectedScreen === mini)

        workspace.selectFavorite(favorite, from: mini, ifStillShowing: mini.currentConversationID)
        #expect(workspace.selectedScreen === book)
        #expect(book.newChatDraftID != hiddenDraft)
        #expect(book.workingDirectory == "/Users/developer/ExampleLibrary")
        #expect(await book.prepareDraft())
        #expect(book.input.isEmpty)
        #expect(mini.workingDirectory == "/Users/developer/RemoteCoder")
        book.openUnsentDraft(hiddenDraft)
        #expect(await book.prepareDraft())
        #expect(book.input == "other machine")
        #expect(book.workingDirectory == "/Users/developer/RemoteCoder")
    }

    @Test func renamingAHostRelabelsItWithoutReplacingItsModel() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        #expect(mini.target.hostDisplayName == "Mac Mini")

        var renamed = fixture.mini
        renamed.name = "Studio"
        fixture.workspace.settings.upsert(renamed)
        fixture.workspace.reconcileHosts()

        #expect(fixture.workspace.screen(for: fixture.mini.id) === mini)
        #expect(mini.target.hostDisplayName == "Studio")
        #expect(mini.isRetired == false)
    }

    @Test func pinAndSelectionCommandsFollowTheAddressedHost() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))

        let shared = "0199-shared"
        let miniAddress = ConversationAddress(hostID: fixture.mini.id, threadID: shared)
        let bookAddress = ConversationAddress(hostID: fixture.book.id, threadID: shared)

        fixture.workspace.pin(miniAddress, name: "Mini side")
        #expect(fixture.workspace.pinnedName(for: miniAddress) == "Mini side")
        // The same thread id on the other host is a different conversation.
        #expect(fixture.workspace.pinnedName(for: bookAddress) == nil)
        #expect(book.target.conversationList.marks.pinNames.isEmpty)

        fixture.workspace.pin(miniAddress, name: "Mini renamed")
        #expect(mini.target.conversationList.marks.pinName(for: shared) == "Mini renamed")
        fixture.workspace.unpin(miniAddress)
        #expect(fixture.workspace.pinnedName(for: miniAddress) == nil)

        // Selecting a row that host already has open only changes the visible
        // host; it must not re-resume anything.
        book.activeConversation = try fixture.thread(shared, updatedAt: 20)
        fixture.workspace.selectConversation(at: bookAddress)
        #expect(fixture.workspace.selectedHostID == fixture.book.id)
        #expect(fixture.workspace.selectedScreen === book)
    }

    @Test func aRowSwitchCommitsAfterTheTapAndYieldsToNewerNavigation() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let mini = try #require(workspace.screen(for: fixture.mini.id))
        let book = try #require(workspace.screen(for: fixture.book.id))
        mini.activeConversation = try fixture.thread("mini-open", updatedAt: 10)
        book.activeConversation = try fixture.thread("book-open", updatedAt: 20)
        let miniAddress = ConversationAddress(hostID: fixture.mini.id, threadID: "mini-open")
        let bookAddress = ConversationAddress(hostID: fixture.book.id, threadID: "book-open")
        workspace.selectConversation(at: miniAddress)

        #expect(workspace.switchConversation(to: bookAddress) == .changed)
        #expect(workspace.selectedScreen === mini)
        #expect(await waitUntil { workspace.selectedScreen === book })

        #expect(workspace.switchConversation(to: miniAddress) == .changed)
        workspace.select(target: book.executionTarget)
        await Task {}.value
        #expect(workspace.selectedScreen === book)
    }

    @Test(.timeLimit(.minutes(1))) func reselectingTheOpenConversationCancelsAnUncachedHeader() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_pending")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        screen.activeConversation = try fixture.thread("claude_open", updatedAt: 1)
        let original = ConversationAddress(hostID: screen.hostID, threadID: "claude_open")
        let pending = ConversationAddress(hostID: screen.hostID, threadID: "claude_pending")
        let opening = try #require(workspace.selectConversation(at: pending))
        await gateway.waitForHeldThreadRead()

        workspace.selectConversation(at: original)

        #expect(opening.isCancelled)
        await gateway.releaseHeldThreadRead()
        await opening.value
        #expect(workspace.isShowingConversation(at: original, on: workspace.selectedScreen))
    }

    @Test(.timeLimit(.minutes(1))) func aQueuedRowSwitchCancelsTheOldHeaderBeforeItsCommit() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_pending")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        screen.activeConversation = try fixture.thread("claude_open", updatedAt: 1)
        let latest = try fixture.thread("claude_latest", updatedAt: 2)
        await screen.target.conversationList.record(latest)
        let pending = ConversationAddress(hostID: screen.hostID, threadID: "claude_pending")
        let destination = ConversationAddress(hostID: screen.hostID, threadID: latest.id)
        let opening = try #require(workspace.selectConversation(at: pending))
        await gateway.waitForHeldThreadRead()

        #expect(workspace.switchConversation(to: destination) == .changed)
        #expect(screen.activeConversation?.id == "claude_open")
        #expect(opening.isCancelled)
        await gateway.releaseHeldThreadRead()
        await opening.value
        #expect(await waitUntil { workspace.isShowingConversation(at: destination, on: workspace.selectedScreen) })
    }

    @Test(.timeLimit(.minutes(1))) func quickEntryNewChatCancelsAnUncachedDestinationWhileAlreadyInNewChat() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_pending")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        #expect(await screen.prepareDraft())
        let source = try #require(screen.currentDraft)
        #expect(await screen.prepareDraft())
        screen.input = "Keep this new-chat draft"
        let session = QuickEntrySession(workspace: workspace, window: workspace.keyWindow, recents: [])
        let address = ConversationAddress(hostID: screen.hostID, threadID: "claude_pending")
        let row = ConversationSidebarRow(id: address.id, address: address, hostName: "Fixture", showsHostLabel: false,
            title: "Pending", preview: "", sidebarDate: .distantPast, dateLabel: "", ageLabel: "", workingDirectory: "",
            isPinned: false, isUnread: false, isSelected: false, isLoading: false, activity: nil)

        let transfer = try #require(session.target(row))
        await gateway.waitForHeldThreadRead()
        #expect(screen.activeSessionID == nil)
        session.startNewChat()
        await gateway.releaseHeldThreadRead()
        await transfer.value

        #expect(screen.activeSessionID == nil)
        #expect(screen.currentDraft === source)
        #expect(screen.input == "Keep this new-chat draft")
    }

    @Test(.timeLimit(.minutes(1))) func quickEntryCarriesTheLatestDraftAfterAnUncachedHeaderCommits() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_destination")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        #expect(await screen.prepareDraft())
        let source = try #require(screen.currentDraft)
        #expect(await screen.prepareDraft())
        screen.input = "Initial draft"
        let session = QuickEntrySession(workspace: workspace, window: workspace.keyWindow, recents: [])
        let address = ConversationAddress(hostID: screen.hostID, threadID: "claude_destination")
        let row = ConversationSidebarRow(id: address.id, address: address, hostName: "Fixture", showsHostLabel: false,
            title: "Destination", preview: "", sidebarDate: .distantPast, dateLabel: "", ageLabel: "", workingDirectory: "",
            isPinned: false, isUnread: false, isSelected: false, isLoading: false, activity: nil)

        let transfer = try #require(session.target(row))
        await gateway.waitForHeldThreadRead()
        #expect(screen.currentDraft === source)
        #expect(screen.input == "Initial draft")
        let pasteID = UUID()
        let content = ComposerDocumentContent(runs: [.text("    Edited while "),
            .paste(.init(id: pasteID, text: "the header was loading")), .text("  \r\n")])
        let file = ComposerAttachment.file(.init(id: UUID(), name: "report.txt", byteCount: 2,
            placement: .uploaded(.init(path: "/host/uploads/report.txt", bytes: 2, sha256: "ff"))))
        screen.drafts.setContent(content, in: source)
        screen.drafts.setAttachments([file], in: source)
        await gateway.releaseHeldThreadRead()
        await transfer.value

        #expect(workspace.isShowingConversation(at: address, on: screen))
        #expect(screen.composerDocument?.content == content)
        #expect(screen.composerAttachments == [file])
        #expect(source.document?.isEmpty == true)
        #expect(source.attachments.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func quickEntryKeepsAnOriginalDraftWhoseFileBecomesUnfinishedDuringNavigation() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_destination")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        #expect(await screen.prepareDraft())
        let source = try #require(screen.currentDraft)
        #expect(await screen.prepareDraft())
        screen.input = "Keep this draft"
        let session = QuickEntrySession(workspace: workspace, window: workspace.keyWindow, recents: [])
        let address = ConversationAddress(hostID: screen.hostID, threadID: "claude_destination")
        let row = ConversationSidebarRow(id: address.id, address: address, hostName: "Fixture", showsHostLabel: false,
            title: "Destination", preview: "", sidebarDate: .distantPast, dateLabel: "", ageLabel: "", workingDirectory: "",
            isPinned: false, isUnread: false, isSelected: false, isLoading: false, activity: nil)
        let transfer = try #require(session.target(row))
        await gateway.waitForHeldThreadRead()
        let file = ComposerAttachment.file(.init(id: UUID(), name: "report.txt", byteCount: 2,
            placement: .staged(fileName: "report.txt")))
        screen.drafts.setAttachments([file], in: source)
        await gateway.releaseHeldThreadRead()
        await transfer.value

        #expect(workspace.isShowingConversation(at: address, on: screen))
        #expect(screen.composerDocument?.isEmpty == true)
        #expect(screen.composerAttachments.isEmpty)
        #expect(source.document?.content.expandedText == "Keep this draft")
        #expect(source.attachments == [file])
    }

    @Test(.timeLimit(.minutes(1))) func aLaterRowChoiceSupersedesAnAgentChildHeader() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_child")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        screen.activeConversation = try fixture.thread("claude_parent", updatedAt: 1)
        let latest = try fixture.thread("claude_latest", updatedAt: 2)
        await screen.target.conversationList.record(latest)
        let parent = ConversationAddress(hostID: screen.hostID, threadID: "claude_parent")
        let destination = ConversationAddress(hostID: screen.hostID, threadID: latest.id)
        let agent = ConversationAgent(id: "fixture-agent", parentId: nil, ownerThreadId: parent.threadID,
            threadId: "claude_child", provider: .init(rawValue: "claude"), source: "native", title: "Child",
            model: nil, state: .completed, capabilities: .init(inspect: true, openConversation: true,
                message: false, continueWork: false, stop: false, askParent: false),
            executionId: nil, accountId: nil, lastActiveAt: nil)
        let opening = Task { try await workspace.openAgentConversation(agent, from: parent) }
        await gateway.waitForHeldThreadRead()

        #expect(workspace.switchConversation(to: destination) == .changed)
        await gateway.releaseHeldThreadRead()
        try await opening.value

        #expect(await waitUntil { workspace.isShowingConversation(at: destination, on: workspace.selectedScreen) })
        #expect(workspace.agentNavigation == nil)
    }

    @Test(.timeLimit(.minutes(1))) func anAgentChildHeaderCommitsWhenItsIntentIsCurrent() async throws {
        let gateway = try FakeGatewayServer(threadID: "claude_child")
        await gateway.holdThreadRead()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldThreadRead(); await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.selectedScreen)
        screen.activeConversation = try fixture.thread("claude_parent", updatedAt: 1)
        let parent = ConversationAddress(hostID: screen.hostID, threadID: "claude_parent")
        let child = ConversationAddress(hostID: screen.hostID, threadID: "claude_child")
        let agent = ConversationAgent(id: "fixture-agent", parentId: nil, ownerThreadId: parent.threadID,
            threadId: child.threadID, provider: .init(rawValue: "claude"), source: "native", title: "Child",
            model: nil, state: .completed, capabilities: .init(inspect: true, openConversation: true,
                message: false, continueWork: false, stop: false, askParent: false),
            executionId: nil, accountId: nil, lastActiveAt: nil)
        let opening = Task { try await workspace.openAgentConversation(agent, from: parent) }
        await gateway.waitForHeldThreadRead()
        await gateway.releaseHeldThreadRead()
        try await opening.value

        #expect(workspace.isShowingConversation(at: child, on: workspace.selectedScreen))
        #expect(workspace.agentNavigation == AgentNavigation(parent: parent, child: child))
    }

    @Test func sidebarRowsCarryHostQualifiedAddressesForBothHosts() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))

        await mini.target.conversationList.record(try fixture.thread("shared", updatedAt: 50))
        var completed = try fixture.thread("book-only", updatedAt: 30)
        completed.lastTurnCompletedAt = 30
        await book.target.conversationList.record(try fixture.thread("shared", updatedAt: 50))
        await book.target.conversationList.record(completed)

        let rows = fixture.workspace.sidebarSnapshot(arrangedBy: .live(at: .now), in: fixture.workspace.keyWindow).items.compactMap { item in
            if case let .row(row) = item { row } else { nil }
        }
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.address)) == [
            ConversationAddress(hostID: fixture.mini.id, threadID: "shared"),
            ConversationAddress(hostID: fixture.book.id, threadID: "shared"),
            ConversationAddress(hostID: fixture.book.id, threadID: "book-only"),
        ])
        #expect(rows.map(\.showsHostLabel) == [true, true, true])
        #expect(rows.first?.address.threadID == "book-only")
    }

    @Test func aThreadNameUpdateRetitlesOnlyItsOwnHostsRowAndAPinStillWins() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        await mini.target.conversationList.record(try fixture.thread("shared", updatedAt: 50))
        await book.target.conversationList.record(try fixture.thread("shared", updatedAt: 50))

        await mini.target.apply(gatewayEvent: try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "thread/name/updated",
            params: .object(["threadId": .string("shared"), "threadName": .string("  minne-memory ")]),
            receivedAt: .now, sequence: nil))))

        func titles() -> [UUID: String] {
            Dictionary(uniqueKeysWithValues: fixture.workspace.sidebarSnapshot(arrangedBy: .live(at: .now), in: fixture.workspace.keyWindow).items
                .compactMap { item in if case let .row(row) = item { (row.address.hostID, row.title) } else { nil } })
        }
        #expect(titles() == [fixture.mini.id: "minne-memory", fixture.book.id: "Test"])

        fixture.workspace.pin(ConversationAddress(hostID: fixture.mini.id, threadID: "shared"), name: "Pinned")
        #expect(titles()[fixture.mini.id] == "Pinned")
    }

    @Test func drawerRanksAreCapturedPerHostAndMoveOnlyOnActivity() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        let opened = Date.now
        let now = Int64(opened.timeIntervalSince1970)

        await mini.target.conversationList.record(try fixture.thread("shared", updatedAt: now - 3_600))
        await mini.target.conversationList.recordTurnCompletion(threadID: "shared", completedAt: now - 3_600)
        await book.target.conversationList.record(try fixture.thread("shared", updatedAt: now - 36_000))
        await book.target.conversationList.recordTurnCompletion(threadID: "shared", completedAt: now - 36_000)
        let first = fixture.workspace.captureDrawerOpening(at: opened, in: fixture.workspace.keyWindow)
        #expect(first.ranks(on: mini.executionTarget)["shared"]?.recency == now - 3_600)
        #expect(first.ranks(on: book.executionTarget)["shared"]?.recency == now - 36_000)

        await mini.target.conversationList.record(try fixture.thread("shared", updatedAt: now - 60))
        await book.target.conversationList.record(try fixture.thread("shared", updatedAt: now - 30))
        await book.target.conversationList.recordTurnCompletion(threadID: "shared", completedAt: now - 30)
        let second = fixture.workspace.captureDrawerOpening(at: opened.addingTimeInterval(120), in: fixture.workspace.keyWindow)
        #expect(first.ranks(on: book.executionTarget)["shared"]?.recency == now - 36_000)
        #expect(second.ranks(on: mini.executionTarget)["shared"]?.recency == now - 3_600)
        #expect(second.ranks(on: book.executionTarget)["shared"]?.recency == now - 30)
    }

    @Test func eachWindowHasItsOwnScreensAndNewChatDraft() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let first = workspace.attachWindow(opening: nil)
        let second = workspace.attachWindow(opening: nil)
        let target = ExecutionTarget(hostID: fixture.mini.id)

        #expect(first !== second)
        #expect(first.isPrimary)
        #expect(!second.isPrimary)
        let firstScreen = try #require(first.screen(for: target))
        let secondScreen = try #require(second.screen(for: target))
        #expect(firstScreen !== secondScreen)
        #expect(firstScreen.newChatDestination != secondScreen.newChatDestination)
        #expect(secondScreen.newChatDestination == .newChat(second.id))
        #expect(firstScreen.target === secondScreen.target)

        #expect(await firstScreen.prepareDraft())
        firstScreen.input = "first window draft"
        #expect(secondScreen.input.isEmpty)
    }

    @Test func aWindowSelectsItsOwnTargetAndClosingItLeavesTheOtherRunning() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let first = workspace.attachWindow(opening: nil)
        let second = workspace.attachWindow(opening: nil)
        let mini = try #require(workspace.model(for: fixture.mini.id))
        let book = try #require(workspace.model(for: fixture.book.id))

        workspace.select(hostID: fixture.book.id)

        #expect(first.selectedTarget?.hostID == fixture.book.id)
        #expect(second.selectedTarget?.hostID == fixture.mini.id)
        #expect(mini.isVisible)
        #expect(book.isVisible)

        workspace.detachWindow(second)

        #expect(!mini.isRetired)
        #expect(!mini.isVisible)
        #expect(book.isVisible)
        #expect(workspace.keyWindow === first)
    }
}
