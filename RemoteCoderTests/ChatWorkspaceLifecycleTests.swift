import Foundation
import SQLite3
import Testing
import SwiftUI
import UserNotifications
import SpeechKit
@testable import RemoteCoder

/// Ownership and lifecycle: what a host's model may still do after that host is
/// removed, reconfigured or hidden, and what the workspace must re-derive when a
/// host's known history changes.
@MainActor
struct ChatWorkspaceLifecycleTests {

    enum AdmissionTransition: CaseIterable { case inactive, pumpReplacement }

    @Test(arguments: AdmissionTransition.allCases)
    func lifecycleAdmissionUsesTheDeliveringPumpLifetime(_ transition: AdmissionTransition) async throws {
        let gateway = try FakeGatewayServer(threadID: "pump-lifetime")
        defer { await gateway.stop() }
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        let target = screen.target
        let thread = try fixture.thread("pump-lifetime", updatedAt: 1)
        await target.conversationList.record(thread)
        screen.setActiveSessionID(thread.id)
        let sink = AdmissionLifecycleSink(target: target)
        let pump = GatewayEventPump(gateway: target.gatewayClient, conversations: target.conversations, sink: sink)
        defer { for task in pump.stop() { await task.value } }
        pump.startIfNeeded()
        try #require(await waitUntil { sink.connected })
        _ = target.turns.adopt(threadID: thread.id, turnID: "turn")
        try #require(target.turns.busyThreadIDs.contains(thread.id))
        try #require(await target.conversations.existingSession(threadID: thread.id) == nil)

        let index = target.sessionIndex
        let entered = TestFlag()
        let release = DispatchSemaphore(value: 0)
        let heldIndex = Task.detached { await index.holdAdmissionLookup(entered: entered, release: release) }
        defer { release.signal(); _ = await heldIndex.value }
        try #require(await waitUntil { entered.value })
        try await gateway.notify("turn/completed", ["threadId": .string(thread.id),
            "turn": .object(["id": .string("turn"), "status": .string("completed"), "completedAt": .number(20)])])
        try #require(await waitUntil { sink.delivering })
        #expect(!sink.finished)
        var replacedTasks: [Task<Void, Never>] = []
        defer { for task in replacedTasks { await task.value } }
        switch transition {
        case .inactive:
            await target.handleScenePhaseInactive()
        case .pumpReplacement:
            replacedTasks = pump.stop()
            pump.startIfNeeded()
        }
        release.signal()
        #expect(await heldIndex.value)
        try #require(await waitUntil { sink.finished })
        #expect(target.acceptsWork)
        switch transition {
        case .inactive:
            #expect(!target.turns.busyThreadIDs.contains(thread.id))
            #expect(target.conversationList.header(id: thread.id)?.lastTurnCompletedAt == 20)
            let session = try #require(await target.conversations.existingSession(threadID: thread.id))
            #expect(await session.snapshot().lastTurnCompletedAt == 20)
        case .pumpReplacement:
            #expect(target.turns.busyThreadIDs.contains(thread.id))
            #expect(target.conversationList.header(id: thread.id)?.lastTurnCompletedAt == nil)
            #expect(await target.conversations.existingSession(threadID: thread.id) == nil)
        }
    }

    @Test func cancellingLifecycleDeliveryDuringAdmissionLeavesBusyAndCompletionStateUntouched() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        let thread = try fixture.thread("cancelled-lifecycle", updatedAt: 1)
        await screen.target.conversationList.record(thread)
        screen.setActiveSessionID(thread.id)
        let started = try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "turn/started", params: .object(["threadId": .string(thread.id),
                "turn": .object(["id": .string("turn"), "status": .string("inProgress")])]), receivedAt: .now, sequence: nil)))
        await screen.target.apply(gatewayEvent: started)
        try #require(screen.target.turns.busyThreadIDs.contains(thread.id))
        let completed = try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "turn/completed", params: .object(["threadId": .string(thread.id),
                "turn": .object(["id": .string("turn"), "status": .string("completed"), "completedAt": .number(20)])]),
            receivedAt: .now, sequence: nil)))
        let index = screen.target.sessionIndex
        let entered = TestFlag()
        let release = DispatchSemaphore(value: 0)
        let heldIndex = Task.detached { await index.holdAdmissionLookup(entered: entered, release: release) }
        defer { release.signal(); _ = await heldIndex.value }
        try #require(await waitUntil { entered.value })
        let delivering = TestFlag()
        let finished = TestFlag()
        let delivery = Task {
            delivering.value = true
            await screen.target.apply(gatewayEvent: completed)
            finished.value = true
        }
        defer { delivery.cancel(); release.signal(); await delivery.value }
        try #require(await waitUntil { delivering.value })
        #expect(!finished.value)
        delivery.cancel()
        release.signal()
        await delivery.value
        #expect(await heldIndex.value)
        #expect(delivery.isCancelled)
        #expect(screen.target.acceptsWork)
        #expect(screen.target.turns.busyThreadIDs.contains(thread.id))
        #expect(screen.target.conversationList.header(id: thread.id)?.lastTurnCompletedAt == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondQuitJoinsAnExplicitRetirementRetryAfterKeepOpen() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.screen(for: fixture.mini.id))
        try #require(await screen.prepareDraft())
        try #require(await screen.target.drafts.flush())
        let draft = try #require(await screen.target.drafts.draft(for: screen.newChatDestination))
        let recordingID = UUID()
        let directory = fixture.temporaryStorage.storage.directory(for: .target(hostID: fixture.mini.id)).appending(path: "drafts")
        let conflictingID = UUID()
        try await writeConflictingDraft(id: conflictingID, destination: draft.destination, directory: directory)
        screen.input = "Save this draft through the second quit"
        try await screen.target.drafts.appendDictation("and dictation", recordingID: recordingID, to: draft)
        var changed = fixture.mini
        changed.port = 3
        #expect(workspace.settings.upsert(changed))
        workspace.reconcileHosts()
        #expect(await workspace.finishHostChanges() == false)
        workspace.beginTermination()
        #expect(await workspace.flushForTermination().contains { $0.hasPrefix("Mac Mini: Drafts:") })
        workspace.resumeAfterTermination()
        let failure = try #require(workspace.draftRetirementFailure(for: screen.executionTarget))
        try await writeConflictingDraft(id: conflictingID, destination: "thread:other-owner", directory: directory)

        workspace.retryDraftRetirement(failure.target)
        #expect(workspace.isRetryingDraftRetirement(failure.target))
        workspace.beginTermination()
        #expect(await workspace.flushForTermination().isEmpty)
        #expect(await workspace.finishHostChanges())
        #expect(workspace.draftRetirementFailure(for: failure.target) == nil)
        workspace.resumeAfterTermination()
        let replacement = try #require(workspace.model(for: fixture.mini.id))
        #expect(await replacement.drafts.draft(for: screen.newChatDestination)?.document?.content.expandedText == "Save this draft through the second quit and dictation")
        #expect(try await replacement.drafts.hasSavedReceipt(for: recordingID))
    }

    @Test(.timeLimit(.minutes(1))) func quitDuringSuccessfulRetirementJoinsItsDraftSaveWithoutReportingFailure() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.screen(for: fixture.book.id))
        try #require(await screen.prepareDraft())
        screen.input = "Saved while retiring on quit"
        let directory = fixture.temporaryStorage.storage.directory(for: .target(hostID: fixture.book.id)).appending(path: "drafts")
        workspace.settings.delete(fixture.book)
        workspace.reconcileHosts()
        workspace.beginTermination()
        #expect(screen.target.isRetired)
        #expect(!workspace.models.contains { $0 === screen.target })

        #expect(await workspace.flushForTermination().isEmpty)
        #expect(await workspace.finishHostChanges())
        let cold = ComposerDraftStore(directory: directory)
        defer { await cold.retire() }
        #expect(await cold.draft(for: screen.newChatDestination)?.document?.content.expandedText == "Saved while retiring on quit")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func quitRetainsAFailedRetirementDraftAndItsDictationReceiptUntilRetry(_ repairsBeforeQuit: Bool) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.screen(for: fixture.mini.id))
        try #require(await screen.prepareDraft())
        try #require(await screen.target.drafts.flush())
        let draft = try #require(await screen.target.drafts.draft(for: screen.newChatDestination))
        let recordingID = UUID()
        let directory = fixture.temporaryStorage.storage.directory(for: .target(hostID: fixture.mini.id)).appending(path: "drafts")
        let conflictingID = UUID()
        try await writeConflictingDraft(id: conflictingID, destination: draft.destination, directory: directory)
        screen.input = "Retain this draft on quit"
        try await screen.target.drafts.appendDictation("and dictation", recordingID: recordingID, to: draft)
        var changed = fixture.mini
        changed.port = 3
        #expect(workspace.settings.upsert(changed))
        workspace.reconcileHosts()
        #expect(await workspace.finishHostChanges() == false)
        let failure = try #require(workspace.draftRetirementFailure(for: screen.executionTarget))
        func repairCollision() async throws {
            try await writeConflictingDraft(id: conflictingID, destination: "thread:other-owner", directory: directory)
        }
        if repairsBeforeQuit { try await repairCollision() }

        workspace.beginTermination()
        let failures = await workspace.flushForTermination()
        #expect(failures.contains { $0.hasPrefix("Mac Mini: Drafts:") })
        #expect(workspace.draftRetirementFailure(for: failure.target)?.target == failure.target)
        #expect(screen.target.drafts.document(for: draft).content.expandedText == "Retain this draft on quit and dictation")
        workspace.resumeAfterTermination()
        #expect(workspace.draftRetirementFailure(for: failure.target)?.target == failure.target)
        #expect(!workspace.isRetryingDraftRetirement(failure.target))
        #expect(workspace.model(for: fixture.mini.id) == nil)

        if !repairsBeforeQuit { try await repairCollision() }
        workspace.retryDraftRetirement(failure.target)
        #expect(await workspace.finishHostChanges())
        let replacement = try #require(workspace.model(for: fixture.mini.id))
        #expect(await replacement.drafts.draft(for: screen.newChatDestination)?.document?.content.expandedText == "Retain this draft on quit and dictation")
        #expect(try await replacement.drafts.hasSavedReceipt(for: recordingID))
    }

    enum PreDispatchStop: CaseIterable { case quit, cancellation }

    @Test func quitRejectsNewNotificationNavigationUntilKeepOpenResumes() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let book = try #require(workspace.screen(for: fixture.book.id))
        let thread = try fixture.thread("quit-notification", updatedAt: 1)
        await book.target.conversationList.record(thread)
        let payload = TaskCompletionNotificationPayload(eventID: "quit-notification", source: .codex, outcome: .success,
            conversationID: nil, sessionID: thread.id, hostID: fixture.book.id, promptPreview: "", messagePreview: "Done",
            workingDirectory: nil, createdAtUnixSeconds: 1_790_000_000)
        var dismissals = 0
        workspace.notificationSurfaces.register(id: UUID()) { dismissals += 1; return true }
        workspace.beginTermination()
        await workspace.handleCompletionNotificationTap(payload: payload)
        #expect(dismissals == 0)
        #expect(workspace.selectedHostID == fixture.mini.id)
        #expect(book.activeSessionID == nil)
        #expect(await workspace.flushForTermination().isEmpty)
        workspace.resumeAfterTermination()
        await workspace.handleCompletionNotificationTap(payload: payload)
        #expect(dismissals == 1)
    }

    @Test(arguments: PreDispatchStop.allCases)
    func stoppingBeforeTranscriptAdmissionRestoresTheDraft(_ stop: PreDispatchStop) async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try #require(fixture.workspace.selectedScreen)
        try #require(await screen.prepareDraft())
        screen.input = "Preserve the exact admitted message"
        let document = try #require(screen.composerDocument)
        let conversationID = screen.currentConversationID
        let sending = Task { await screen.send() }
        let stopped = TestFlag()
        withObservationTracking {
            _ = document.revision
        } onChange: {
            stopped.value = true
            switch stop {
            case .quit: MainActor.assumeIsolated { fixture.workspace.beginTermination() }
            case .cancellation: sending.cancel()
            }
        }
        #expect(await sending.value == false)
        #expect(stopped.value)
        let session = await screen.target.conversations.session(conversationID: conversationID, threadID: nil)
        let snapshot = await session.snapshot()
        #expect(snapshot.messages.isEmpty)
        #expect(screen.input == "Preserve the exact admitted message")
        #expect(await gateway.turnStarts.isEmpty)
        #expect(await gateway.steers.isEmpty)
        #expect(await gateway.requests("thread/queue/add").isEmpty)
        fixture.workspace.beginTermination()
        #expect(await fixture.workspace.flushForTermination().isEmpty)
        fixture.workspace.resumeAfterTermination()
        #expect(screen.target.acceptsWork)
        let resumed = await session.snapshot()
        #expect(resumed.messages.isEmpty)
        let reopened = ComposerDraftStore(directory: fixture.temporaryStorage.storage.directory(for: .host(fixture.mini.id)).appending(path: "drafts"))
        #expect(await reopened.draft(for: .newChat(screen.newChatDraftID))?.text == "Preserve the exact admitted message")
        #expect(await gateway.turnStarts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func keepOpenRearmsMetadataStatusObservationForLaterSyncFailures() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try #require(fixture.workspace.selectedScreen)
        await fixture.workspace.bootstrap()
        await screen.target.prepareIfNeeded()
        await screen.target.metadataService.sync()
        #expect(screen.target.metadataStatus.error == nil)
        fixture.workspace.beginTermination()
        #expect(await fixture.workspace.flushForTermination().isEmpty)
        fixture.workspace.resumeAfterTermination()
        await screen.target.prepareIfNeeded()
        await gateway.stop()
        await screen.target.metadataService.sync()
        #expect(await waitUntil { screen.target.metadataStatus.error != nil })
    }

    @Test(.timeLimit(.minutes(1))) func quitClosesIntakeFlushesEveryHostAndKeepOpenRestoresDraftEditing() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        try #require(await mini.prepareDraft())
        try #require(await book.prepareDraft())
        mini.input = "Mini admitted draft"
        book.input = "Book admitted draft"
        fixture.workspace.beginTermination()
        #expect(fixture.workspace.isQuiescing)
        #expect(!mini.target.acceptsWork && !book.target.acceptsWork)
        #expect(!mini.isRetired && !book.isRetired)
        mini.input = "Late mutation"
        #expect(mini.input == "Mini admitted draft")
        #expect(await mini.send() == false)
        let failures = await fixture.workspace.flushForTermination()
        #expect(failures.isEmpty)
        fixture.workspace.resumeAfterTermination()
        #expect(!fixture.workspace.isQuiescing)
        #expect(mini.target.acceptsWork && book.target.acceptsWork)
        mini.input = "Keep Open edit"
        #expect(mini.input == "Keep Open edit")
        fixture.workspace.beginTermination()
        #expect(await fixture.workspace.flushForTermination().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func quitReportsTheFailingHostsCheckpointAndKeepOpenAllowsRetry() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.screen(for: fixture.mini.id))
        try #require(await screen.prepareDraft())
        let session = await screen.target.conversations.session(threadID: "quit-checkpoint")
        await session.appendLocal(ChatMessage(role: .codex, text: "Previous local record"))
        try await session.flush()
        let directory = fixture.temporaryStorage.storage.directory(for: .device).appending(path: "conversations-v1/\(fixture.mini.id)")
        try await withCheckpointWriterLock(directory.appending(path: "\(session.conversationID).sqlite")) {
            await session.ingest(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "answer", text: ""),
                threadID: "quit-checkpoint", turnID: "live", ordinal: 1, startedAtMs: 1, completedAtMs: 1), replay: false)
            await session.ingest(try GatewayEventFixture.delta("Unsaved tail", threadID: "quit-checkpoint", turnID: "live", itemID: "answer"), replay: false)
            fixture.workspace.beginTermination()
            let failures = await fixture.workspace.flushForTermination()
            #expect(failures.contains { $0.hasPrefix("Mac Mini: Conversation checkpoint") })
            #expect(!failures.contains { $0.hasPrefix("MacBook:") })
        }
        fixture.workspace.resumeAfterTermination()
        screen.input = "Normal edit after failure"
        #expect(screen.input == "Normal edit after failure")
        fixture.workspace.beginTermination()
        #expect(await fixture.workspace.flushForTermination().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func quittingDuringDictationKeepsTheAudioRecoverableWithoutTranscribingIt() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = StubVoiceRecorder()
        try #require(await screen.prepareDraft())
        screen.target.voice = VoiceInputController(access: .fixture, owner: screen.executionTarget,
            transcriber: StubTranscriber(text: "Do not silently discard audio"), recorder: recorder, recordings: recordings.store)
        screen.micTapStart()
        await screen.micTapStartAsync()
        fixture.workspace.beginTermination()
        #expect(await fixture.workspace.flushForTermination().isEmpty)
        #expect(recorder.didStop && recorder.didDeactivate)
        let saved = try await screen.target.voice.savedRecordings()
        #expect(saved.count == 1)
        #expect(saved.first?.duration == .milliseconds(100))
        #expect(screen.input.isEmpty)
        fixture.workspace.resumeAfterTermination()
        #expect(await waitUntil { screen.recoverableDictations.count == 1 })
        screen.transcribeRecoverableDictation(try #require(saved.first?.id))
        #expect(await waitUntil { screen.input == "Do not silently discard audio" })
    }

    @Test(.timeLimit(.minutes(1))) func quitJoinsAHostRetirementAlreadyAdmittedAndReportsItsUnsavedCheckpoint() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.screen(for: fixture.book.id))
        let session = await screen.target.conversations.session(threadID: "retiring-checkpoint")
        await session.appendLocal(ChatMessage(role: .codex, text: "Previous local record"))
        try await session.flush()
        let directory = fixture.temporaryStorage.storage.directory(for: .device).appending(path: "conversations-v1/\(fixture.book.id)")
        try await withCheckpointWriterLock(directory.appending(path: "\(session.conversationID).sqlite")) {
            await session.ingest(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "answer", text: ""),
                threadID: "retiring-checkpoint", turnID: "live", ordinal: 1, startedAtMs: 1, completedAtMs: 1), replay: false)
            await session.ingest(try GatewayEventFixture.delta("Unsaved retiring tail", threadID: "retiring-checkpoint", turnID: "live", itemID: "answer"), replay: false)
            fixture.workspace.settings.delete(fixture.book)
            fixture.workspace.reconcileHosts()
            fixture.workspace.beginTermination()
            #expect(screen.target.isRetired)
            #expect(!fixture.workspace.models.contains { $0 === screen.target })
            let failures = await fixture.workspace.flushForTermination()
            #expect(failures.contains { $0.hasPrefix("MacBook: Conversation checkpoint") })
            #expect(!failures.contains { $0.hasPrefix("Mac Mini:") })
        }
        fixture.workspace.resumeAfterTermination()
        #expect(screen.target.isRetired)
        #expect(fixture.workspace.selectedScreen?.target.acceptsWork == true)
    }

    @Test func relaunchJoinsEveryPreviousDraftOwnerBeforeRestoring() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let original = try #require(fixture.workspace.selectedScreen)
        try #require(await original.prepareDraft())
        let draftID = try #require(original.currentDraft).id
        original.input = "Keep this draft across both launches"

        let first = try await fixture.relaunch()
        #expect(original.target.isRetired)
        let firstScreen = try #require(first.selectedScreen)
        try #require(await firstScreen.prepareDraft())
        #expect(firstScreen.currentDraft?.id == draftID)
        #expect(firstScreen.input == "Keep this draft across both launches")

        let second = try await fixture.relaunch()
        #expect(firstScreen.target.isRetired)
        let secondScreen = try #require(second.selectedScreen)
        try #require(await secondScreen.prepareDraft())
        #expect(secondScreen.currentDraft?.id == draftID)
        #expect(secondScreen.input == "Keep this draft across both launches")
    }

    @Test(arguments: WarmingBlocker.allCases)
    func speculativeHistoryIsBlockedForHiddenInactiveAndConstrainedHosts(_ blocker: WarmingBlocker) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let normal = AppEnergyPolicy(isLowPowerModeEnabled: false, thermalState: .nominal)
        try #require(await waitUntil { model.target.shouldWarmConversations(policy: normal) },
                     "A visible, active host on an unmetered network warms conversations")
        var policy = normal
        switch blocker {
        case .lowPower: policy = AppEnergyPolicy(isLowPowerModeEnabled: true, thermalState: .nominal)
        case .seriousThermalState: policy = AppEnergyPolicy(isLowPowerModeEnabled: false, thermalState: .serious)
        case .hidden: model.setPresentation(TargetPresentation(presented: false))
        case .inactiveScene: await model.target.handleScenePhaseInactive()
        case .retired: model.target.beginRetirement()
        }
        #expect(!model.target.shouldWarmConversations(policy: policy))
    }

    // MARK: - Retirement fences

    @Test func removingAHostRetiresItsModelBeforeItLeavesTheRegistry() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))

        fixture.workspace.settings.delete(fixture.book)
        fixture.workspace.reconcileHosts()

        // Synchronously, with no awaits in between: any suspended work inside the
        // model resumes to a retired object, never to a live one.
        #expect(book.isRetired)
        #expect(fixture.workspace.model(for: fixture.book.id) == nil)
        #expect(fixture.workspace.models.contains { $0 === book.target } == false)
        #expect(fixture.workspace.hasMultipleHosts == false)
        #expect(fixture.workspace.sidebarSnapshot(arrangedBy: .live(at: .now), in: fixture.workspace.keyWindow).hostStates.map(\.hostID) == [fixture.mini.id])
    }

    @Test(arguments: [false, true])
    func aHistoryInvalidationPendingAtRetirementNavigatesNothing(removed: Bool) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        mini.setActiveSessionID("invalidated")
        let navigated = TestFlag()
        mini.target.onConversationNavigation = { navigated.value = true }

        await mini.target.apply(gatewayEvent: .historyInvalidated(threadID: "invalidated", removed: removed, sequence: nil))
        await mini.target.retire()

        #expect(!navigated.value)
        #expect(mini.activeSessionID == "invalidated")
    }

    @Test(.timeLimit(.minutes(1))) func aModelRetiredWhileBootstrapWasSuspendedStartsNothingNew() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let finished = TestFlag()

        let prepare = Task { @MainActor in
            await mini.target.prepareIfNeeded()
            finished.value = true
        }
        await gateway.waitForRequest("initialize")

        fixture.workspace.settings.delete(fixture.mini)
        fixture.workspace.reconcileHosts()
        #expect(mini.isRetired)

        await prepare.value
        await mini.target.retire()
        #expect(finished.value)
        #expect(await mini.target.gatewayClient.isConnected == false)
        await #expect(throws: GatewayClient.ClientError.self) {
            try await mini.target.gatewayClient.connectIfNeeded()
        }
    }

    @Test(.timeLimit(.minutes(1))) func aReconfiguredHostsRetiredModelCannotPublishIntoItsReplacement() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let original = try #require(fixture.workspace.screen(for: fixture.mini.id))
        #expect(await original.prepareDraft())
        original.input = "draft on the old address"

        var moved = fixture.mini
        moved.authToken = "rotated-token"
        fixture.workspace.settings.upsert(moved)
        fixture.workspace.reconcileHosts()

        await fixture.workspace.finishHostChanges()
        let replacement = try #require(fixture.workspace.screen(for: fixture.mini.id))
        #expect(replacement !== original)
        #expect(original.isRetired)
        #expect(original.target.isVisible == false)
        #expect(replacement.target.isVisible)

        // A send arriving after retirement never reaches the wire: no dispatch is
        // registered, no gateway error bubble appears, and nothing lands in the
        // replacement that now owns the address.
        let messagesBefore = original.messages.count
        original.input = "too late"
        #expect(await original.send() == false)
        #expect(original.messages.count == messagesBefore)
        #expect(original.messages.contains { $0.text.contains("⛔️") } == false)
        #expect(original.target.turns.jobs.isEmpty)
        #expect(await gateway.requests("turn/start").isEmpty)
        #expect(replacement.messages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func backgroundingCancelsAForegroundFanOutThatHasNotFinished() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))

        let foreground = Task { await fixture.workspace.handleScenePhaseActive() }
        await gateway.waitForRequest("initialize")
        await fixture.workspace.handleScenePhaseBackground()
        await foreground.value

        #expect(await mini.target.gatewayClient.isConnected == false)
    }

    @Test(.timeLimit(.minutes(1))) func reactivatingDuringABackgroundPassLeavesEveryHostForeground() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        try #require(fixture.workspace.models.map(\.hostID) == [fixture.mini.id, fixture.book.id])
        fixture.workspace.select(hostID: fixture.book.id)

        let background = Task { await fixture.workspace.handleScenePhaseBackground() }
        await Task.yield()
        try #require(mini.target.isSceneLive == false && book.target.isSceneLive,
                     "The background pass is suspended inside the first host")

        await fixture.workspace.handleScenePhaseActive()
        await background.value

        #expect(mini.target.isSceneLive)
        #expect(book.target.isSceneLive)
    }

    @Test(.timeLimit(.minutes(1))) func aHiddenIdleHostStaysOffTheNetworkUntilItIsShown() async throws {
        let gateway = try FakeGatewayServer()
        let fixture = await WorkspaceFixture(bookGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        try #require(book.target.isVisible == false)

        await book.target.handleScenePhaseActive()
        #expect(await waitUntil(timeout: .seconds(1)) { await gateway.connectionCount > 0 } == false)
        #expect(await gateway.claudeHTTPRequests.isEmpty)

        fixture.workspace.select(hostID: fixture.book.id)
        #expect(await waitUntil { await gateway.connectionCount > 0 })
    }

    @Test func retirementJoinsCleanupEvenWhenTheWorkspaceAlreadyFencedTheModel() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        fixture.workspace.settings.delete(fixture.book)
        fixture.workspace.reconcileHosts()
        async let first = book.target.retire()
        async let second = book.target.retire()
        let outcomes = await (first, second)
        #expect(outcomes.0)
        #expect(outcomes.1)
        await #expect(throws: HostDirectoriesError.self) {
            _ = try await book.target.directories.resolveHomePath()
        }
        await #expect(throws: GatewayClient.ClientError.self) {
            try await book.target.gatewayClient.connectIfNeeded()
        }
    }

    @Test func simultaneousSendsAdmitOnlyOneCopyOfAnUnchangedDraft() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        model.input = "Exactly one user message"
        async let first = model.send()
        async let second = model.send()
        let accepted = await [first, second]
        #expect(accepted.filter { $0 }.count == 1)
        #expect(model.messages.filter { $0.role == .user }.count == 1)
    }

    // MARK: - One authoritative registry (observation)

    @Test func replacingAHostsModelInvalidatesTheViewsBoundToIt() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let original = try #require(fixture.workspace.selectedScreen)
        let invalidated = TestFlag()

        // Exactly what `ChatRootView.body` reads.
        withObservationTracking {
            _ = fixture.workspace.selectedModel
        } onChange: {
            invalidated.value = true
        }

        var moved = fixture.mini
        moved.hostname = "127.0.0.2"
        fixture.workspace.settings.upsert(moved)
        fixture.workspace.reconcileHosts()

        #expect(invalidated.value)
        await fixture.workspace.finishHostChanges()
        #expect(fixture.workspace.selectedScreen !== original)
        #expect(fixture.workspace.selectedModel?.host.hostname == "127.0.0.2")
        #expect(original.isRetired)
    }

    // MARK: - Device-wide audio

    @Test func hidingAHostFinishesItsDictationIntoItsOwnDraft() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = StubVoiceRecorder()
        mini.target.voice = VoiceInputController(
            access: .fixture,
            owner: mini.executionTarget,
            transcriber: StubTranscriber(text: "hands free note"),
            recorder: recorder,
            recordings: recordings.store
        )
        #expect(await mini.prepareDraft())
        mini.micTapStart()
        await mini.micTapStartAsync()

        fixture.workspace.select(hostID: fixture.book.id)

        // The microphone is released as the host leaves the screen, and the audio
        // it already captured lands in that host's own draft.
        #expect(mini.target.voice.isRecording == false)
        #expect(await waitUntil { mini.input == "hands free note" })
        #expect(recorder.didStop)
        #expect(recorder.didDeactivate)
        #expect(book.input.isEmpty)
        #expect(mini.target.voice.isTranscribing == false)
        #expect(try await waitUntil { try await recordings.listedIDs().isEmpty })
    }

    @Test func onlyTheHostOnScreenOwnsTheAudioRoute() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))

        #expect(mini.target.ownsAudioRoute)
        #expect(book.target.ownsAudioRoute == false)

        fixture.workspace.select(hostID: fixture.book.id)
        #expect(mini.target.ownsAudioRoute == false)
        #expect(book.target.ownsAudioRoute)

        // A retired model never speaks, even if it was the visible one.
        book.target.beginRetirement()
        #expect(book.target.ownsAudioRoute == false)
    }

    @Test func brokerNotificationUsesOneWorkspaceSurfaceAcrossHostsAndLifecycle() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let mini = try #require(workspace.screen(for: fixture.mini.id))
        mini.setActiveSessionID("shared")
        func receive(_ payload: TaskCompletionNotificationPayload, active: Bool = true) async throws -> Bool {
            let json = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
            return await !RemoteCoderAppDelegate.foregroundNotificationOptions(
                userInfo: [TaskCompletionNotificationConstants.userInfoPayloadKey: json],
                applicationIsActive: { active }, workspace: workspace
            ).isEmpty
        }
        func payload(_ event: String, host: UUID, question: String? = nil) -> TaskCompletionNotificationPayload {
            TaskCompletionNotificationPayload(eventID: event, source: .claude,
                outcome: question == nil ? .success : nil, conversationID: nil, sessionID: "shared", hostID: host,
                promptPreview: "Prompt", messagePreview: "Reply", workingDirectory: nil,
                createdAtUnixSeconds: 1_790_000_000, questionItemID: question)
        }
        // UIKit inactivity (including a lock transition) delegates this delivery
        // to the system even when the selected conversation has not changed.
        let inactiveOpen = payload("inactive-open", host: fixture.mini.id)
        #expect(try await receive(inactiveOpen, active: false))
        #expect(workspace.notifications.banner == nil)
        let open = payload("open", host: fixture.mini.id)
        #expect(try await !receive(open))
        #expect(workspace.notifications.banner == nil)
        let otherHost = payload("other-host", host: fixture.book.id)
        #expect(try await !receive(otherHost))
        #expect(workspace.notifications.banner?.payload == otherHost)
        workspace.notifications.dismiss()
        #expect(workspace.notifications.banner == nil)
        // A delayed duplicate cannot become a system alert after an in-app banner.
        #expect(try await !receive(otherHost, active: false))
        let background = payload("background", host: fixture.book.id)
        #expect(try await receive(background, active: false))
        #expect(try await !receive(background))
        #expect(workspace.notifications.banner == nil)
        // A newly delivered delayed push is presented once; socket replay never
        // creates a competing banner or depends on comparing the two hosts' clocks.
        let delayed = payload("delayed", host: fixture.book.id)
        #expect(try await !receive(delayed))
        #expect(workspace.notifications.banner?.payload == delayed)
        let book = try #require(workspace.screen(for: fixture.book.id))
        book.setActiveSessionID("shared")
        workspace.select(hostID: fixture.book.id)
        #expect(workspace.notifications.banner == nil)
        #expect(try await !receive(delayed))
        let question = payload("question:1", host: fixture.mini.id, question: "question-1")
        _ = try await receive(question)
        #expect(workspace.notifications.banner?.payload?.questionItemID == "question-1")
        #expect(workspace.notifications.banner?.delivery.title == "Claude has a question")
    }

    @Test func malformedAndGenericCallbacksUseInAppCopyWithoutNavigation() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let malformed: [AnyHashable: Any] = [TaskCompletionNotificationConstants.userInfoPayloadKey: "{private-content"]
        let options = await RemoteCoderAppDelegate.foregroundNotificationOptions(userInfo: malformed,
            title: "Root alert", body: "Delivered copy", applicationIsActive: { true }, workspace: workspace)
        #expect(options.isEmpty)
        #expect(workspace.notifications.banner?.delivery.title == "Root alert")
        #expect(workspace.notifications.banner?.delivery.body == "Delivered copy")
        #expect(workspace.notifications.banner?.payload == nil)
        await workspace.handleCompletionNotificationTap(payloadJSON: "{private-content")
        #expect(workspace.notificationRoutingError?.contains("no readable conversation identity") == true)
        let wrongType = await RemoteCoderAppDelegate.foregroundNotificationOptions(
            userInfo: [TaskCompletionNotificationConstants.userInfoPayloadKey: 42],
            title: "Unmapped alert", body: "Delivered copy", applicationIsActive: { true }, workspace: workspace)
        #expect(wrongType.isEmpty)
        #expect(workspace.notifications.banner?.delivery.title == "Unmapped alert")
        #expect(workspace.notifications.banner?.delivery.body == "Delivered copy")
        #expect(workspace.notifications.banner?.payload == nil)
        let generic = await RemoteCoderAppDelegate.foregroundNotificationOptions(userInfo: [:],
            title: "Agent update", body: "Ready", applicationIsActive: { true }, workspace: workspace)
        #expect(generic.isEmpty)
        #expect(workspace.notifications.banner?.delivery.title == "Agent update")
        #expect(workspace.notifications.banner?.delivery.body == "Ready")
        #expect(workspace.notifications.banner?.payload == nil)
        let audio = await RemoteCoderAppDelegate.foregroundNotificationOptions(
            userInfo: ["audio_url": "https://example.test/audio", "audio_filename": "speech.caf"],
            title: "Spoken update", body: "Ready", applicationIsActive: { true }, workspace: workspace)
        #expect(audio.contains(.sound))
        #expect(!audio.contains(.banner) && !audio.contains(.list))
        // Expiry is owned by the actual renderer, not an invisible receipt.
        #expect(workspace.notifications.banner != nil)
        workspace.notifications.dismiss()
        let inactive = await RemoteCoderAppDelegate.foregroundNotificationOptions(userInfo: [:],
            title: "Inactive update", body: "Ready", applicationIsActive: { false }, workspace: workspace)
        #expect(!inactive.isEmpty)
        #expect(workspace.notifications.banner == nil)
    }

    @Test func disabledAutomaticAlertsDoNotUseEitherSurfaceEvenWhenMalformed() async {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        for active in [true, false] {
            let options = await RemoteCoderAppDelegate.foregroundNotificationOptions(
                userInfo: [TaskCompletionNotificationConstants.userInfoPayloadKey: "{bad"],
                title: "Completion", body: "Done", applicationIsActive: { active }, workspace: fixture.workspace)
            #expect(options.isEmpty)
            #expect(fixture.workspace.notifications.banner == nil)
        }
    }

    @Test(arguments: ["manual", "newer-tap", "new-chat"])
    func aSuspendedNotificationCannotOverrideNewerNavigation(_ replacement: String) async throws {
        let gate = NotificationReadGate()
        let fixture = await WorkspaceFixture(loadConversationHeader: { owner, id in
            if id == "slow" { return await gate.read() }
            return try await owner.conversationHeader(threadID: id)
        })
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let mini = try #require(workspace.screen(for: fixture.mini.id))
        let book = try #require(workspace.screen(for: fixture.book.id))
        let slowThread = try fixture.thread("slow", updatedAt: 1)
        let newerThread = try fixture.thread("newer", updatedAt: 2)
        await mini.target.conversationList.record(newerThread)
        func notification(_ id: String, host: UUID) -> TaskCompletionNotificationPayload {
            TaskCompletionNotificationPayload(eventID: "question:" + id, source: .codex,
                outcome: nil, conversationID: nil, sessionID: id, hostID: host,
                promptPreview: "Question", messagePreview: "Choose", workingDirectory: nil,
                createdAtUnixSeconds: 1_790_000_000, questionItemID: "question-" + id)
        }
        let earlier = Task { await workspace.handleCompletionNotificationTap(payload: notification("slow", host: fixture.book.id)) }
        defer { gate.release(slowThread); earlier.cancel() }
        try #require(await waitUntil { gate.isWaiting })
        if replacement == "newer-tap" {
            await workspace.handleCompletionNotificationTap(payload: notification("newer", host: fixture.mini.id))
        } else {
            workspace.selectConversation(at: ConversationAddress(hostID: fixture.mini.id, threadID: "newer"))
            if replacement == "new-chat" { mini.startNewConversation() }
        }
        gate.release(slowThread)
        await earlier.value
        #expect(workspace.selectedHostID == fixture.mini.id)
        #expect(mini.activeSessionID == (replacement == "new-chat" ? nil : "newer"))
        #expect(book.activeSessionID == nil)
        #expect(book.questionFocusRequest == nil)
        if replacement == "newer-tap" { #expect(mini.questionFocusRequest?.itemID == "question-newer") }
    }

    @Suite(.serialized)
    @MainActor
    struct LaunchRestore {
        @Test func aRelaunchReopensTheConversationThatWasOpen() async throws {
            let fixture = await WorkspaceFixture()
            defer { await fixture.cleanUp() }
            let book = try #require(fixture.workspace.screen(for: fixture.book.id))
            await book.target.conversationList.record(try fixture.thread("open", updatedAt: 2))
            fixture.workspace.selectConversation(at: ConversationAddress(hostID: fixture.book.id, threadID: "open"))
            await fixture.workspace.retireEverything()

            let relaunched = await relaunch(fixture)
            defer { await relaunched.retireEverything() }
            await relaunched.bootstrap()
            #expect(await waitUntil { relaunched.selectedScreen?.activeSessionID == "open" })
            #expect(relaunched.selectedHostID == fixture.book.id)
        }

        @Test func aRelaunchAfterStartingANewChatStaysOnTheNewChat() async throws {
            let fixture = await WorkspaceFixture()
            defer { await fixture.cleanUp() }
            let book = try #require(fixture.workspace.screen(for: fixture.book.id))
            await book.target.conversationList.record(try fixture.thread("open", updatedAt: 2))
            fixture.workspace.selectConversation(at: ConversationAddress(hostID: fixture.book.id, threadID: "open"))
            book.startNewConversation()
            await fixture.workspace.retireEverything()

            let requested = TestFlag()
            let relaunched = await relaunch(fixture) { owner, id in
                requested.value = true
                return try await owner.conversationHeader(threadID: id)
            }
            defer { await relaunched.retireEverything() }
            await relaunched.bootstrap()
            #expect(relaunched.selectedHostID == fixture.book.id)
            #expect(relaunched.selectedScreen?.activeSessionID == nil)
            #expect(!requested.value)
        }

        @Test func aRelaunchReopensTheUnsentDraftThatWasOnScreen() async throws {
            let fixture = await WorkspaceFixture()
            defer { await fixture.cleanUp() }
            fixture.workspace.select(hostID: fixture.book.id)
            let book = try #require(fixture.workspace.screen(for: fixture.book.id))
            try #require(await book.prepareDraft())
            book.input = "Half-dictated plan"
            book.startNewConversation()
            let second = book.newChatDraftID
            try #require(await book.prepareDraft())
            book.input = "Another idea"
            book.selectModel(try CodexModelFixtures.option(CodexModelFixtures.astraID), for: nil)
            book.selectReasoning(.effort(.high), for: nil)
            NewChatDefaults.recordReasoningSelection(.effort(.low), defaults: book.target.chatDefaults)
            await fixture.workspace.retireEverything()

            let relaunched = await relaunch(fixture)
            defer { await relaunched.retireEverything() }
            await relaunched.bootstrap()
            #expect(relaunched.selectedHostID == fixture.book.id)
            let screen = try #require(relaunched.selectedScreen)
            #expect(screen.newChatDraftID == second)
            #expect(await screen.prepareDraft())
            #expect(screen.input == "Another idea")
            #expect(screen.reasoningSelection == .effort(.high))
            #expect(screen.currentDraft?.newChat?.modelID == CodexModelFixtures.astraID)
            #expect(await waitUntil { screen.target.drafts.unsentDrafts.map(\.title).sorted() == ["Another idea", "Half-dictated plan"] })
        }

        @Test func aNotificationThatLaunchedTheAppWinsOverTheConversationThatWasOpen() async throws {
            let fixture = await WorkspaceFixture()
            defer { await fixture.cleanUp() }
            let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
            let book = try #require(fixture.workspace.screen(for: fixture.book.id))
            await mini.target.conversationList.record(try fixture.thread("tapped", updatedAt: 1))
            await book.target.conversationList.record(try fixture.thread("open", updatedAt: 2))
            fixture.workspace.selectConversation(at: ConversationAddress(hostID: fixture.book.id, threadID: "open"))
            await fixture.workspace.retireEverything()
            let relaunched = await relaunch(fixture)
            defer { await relaunched.retireEverything() }
            let screenID = UUID()
            relaunched.events.register(.init(
                presents: { _ in false },
                perform: { event in
                    guard case .completionNotificationTap(let payloadJSON) = event else { return }
                    Task { await relaunched.handleCompletionNotificationTap(payloadJSON: payloadJSON) }
                }
            ), id: screenID)
            relaunched.events.setActive(true, screen: screenID)
            relaunched.events.receive(.completionNotificationTap(
                payloadJSON: try String(decoding: JSONEncoder().encode(notification("tapped", host: fixture.mini.id)), as: UTF8.self)))
            await relaunched.bootstrap()
            try #require(await waitUntil { relaunched.screen(for: fixture.mini.id)?.activeSessionID == "tapped" })
            #expect(relaunched.selectedHostID == fixture.mini.id)
            #expect(relaunched.screen(for: fixture.mini.id)?.activeSessionID == "tapped")
            #expect(relaunched.screen(for: fixture.book.id)?.activeSessionID == nil)
        }

        @Test(arguments: ["manual", "tap"])
        func navigatingBeforeTheRestoredHeaderArrivesKeepsTheNewerChoice(_ navigation: String) async throws {
            let fixture = await WorkspaceFixture()
            defer { await fixture.cleanUp() }
            let book = try #require(fixture.workspace.screen(for: fixture.book.id))
            let open = try fixture.thread("open", updatedAt: 2)
            await book.target.conversationList.record(open)
            fixture.workspace.selectConversation(at: ConversationAddress(hostID: fixture.book.id, threadID: "open"))
            await fixture.workspace.retireEverything()

            let gate = NotificationReadGate()
            let returned = TestFlag()
            let relaunched = await relaunch(fixture) { owner, id in
                guard id == "open" else { return try await owner.conversationHeader(threadID: id) }
                let thread = await gate.read()
                returned.value = true
                return thread
            }
            defer { gate.release(open) }
            defer { await relaunched.retireEverything() }
            await relaunched.bootstrap()
            try #require(await waitUntil { gate.isWaiting })
            let mini = try #require(relaunched.screen(for: fixture.mini.id))
            await mini.target.conversationList.record(try fixture.thread("newer", updatedAt: 3))
            if navigation == "tap" {
                await relaunched.handleCompletionNotificationTap(payload: notification("newer", host: fixture.mini.id))
            } else {
                relaunched.selectConversation(at: ConversationAddress(hostID: fixture.mini.id, threadID: "newer"))
            }
            gate.release(open)
            #expect(await waitUntil { returned.value })
            #expect(relaunched.selectedHostID == fixture.mini.id)
            #expect(mini.activeSessionID == "newer")
            #expect(relaunched.screen(for: fixture.book.id)?.activeSessionID == nil)
        }

        private func relaunch(
            _ fixture: WorkspaceFixture,
            loadConversationHeader: @escaping @MainActor (ChatTargetModel, String) async throws -> ConversationHeader = {
                try await $0.conversationHeader(threadID: $1)
            }
        ) async -> ChatWorkspaceModel {
            let chatDefaults = fixture.defaults
            let storage = fixture.temporaryStorage.storage
            let workspace = ChatWorkspaceModel(
                settings: fixture.workspace.settings,
                defaults: chatDefaults,
                makeModel: { ChatTargetModel(host: $0, chatDefaults: chatDefaults, modelPickerPreferences: $1, syncedPreferences: $2, voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: storage, htmlVisuals: HTMLVisualServices(directory: storage.root.appending(path: "html-visuals"))) },
                loadConversationHeader: loadConversationHeader,
                voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production,
                storage: storage
            )
            await workspace.finishHostChanges()
            return workspace
        }

        private func notification(_ sessionID: String, host: UUID) -> TaskCompletionNotificationPayload {
            TaskCompletionNotificationPayload(eventID: "completion:" + sessionID, source: .codex,
                outcome: nil, conversationID: nil, sessionID: sessionID, hostID: host,
                promptPreview: "Prompt", messagePreview: "Done", workingDirectory: nil,
                createdAtUnixSeconds: 1_790_000_000, questionItemID: nil)
        }
    }

    @Test func socketCompletionAndReplayNeverCreateAnAlert() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        for replay in [false, true] {
            let event = try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
                method: "turn/completed", params: .object([
                    "threadId": .string("other-thread"),
                    "turn": .object(["id": .string("turn-\(replay)"), "status": .string("completed")])
                ])
            )))
            await mini.target.apply(gatewayEvent: event, replay: replay)
            #expect(fixture.workspace.notifications.banner == nil)
        }
    }

    @Test func aRefusedCoverKeepsTheNotificationRetryableWithoutChangingSelection() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let book = try #require(workspace.screen(for: fixture.book.id))
        let thread = try fixture.thread("covered-target", updatedAt: 1)
        await book.target.conversationList.record(thread)
        let payload = TaskCompletionNotificationPayload(eventID: "covered", source: .codex, outcome: .success,
            conversationID: nil, sessionID: thread.id, hostID: fixture.book.id, promptPreview: "", messagePreview: "Done",
            workingDirectory: nil, createdAtUnixSeconds: 1_790_000_000)
        let surface = UUID()
        workspace.notificationSurfaces.register(id: surface) { false }
        await workspace.handleCompletionNotificationTap(payload: payload)
        #expect(workspace.selectedHostID == fixture.mini.id)
        #expect(book.activeSessionID == nil)
        #expect(workspace.notifications.banner?.payload == payload)
        #expect(workspace.notifications.banner?.delivery.title == "Couldn't open notification")
        workspace.notificationSurfaces.register(id: surface) { true }
        await workspace.handleCompletionNotificationTap(payload: payload)
        #expect(workspace.selectedHostID == fixture.book.id)
        #expect(book.activeSessionID == thread.id)
    }

    @Test(arguments: ["inactive", "background", "reactivated"])
    func aLateCoverRefusalCannotRecreateAnAlertAfterInactivity(_ transition: String) async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let book = try #require(workspace.screen(for: fixture.book.id))
        let payload = TaskCompletionNotificationPayload(eventID: "pending-cover", source: .codex, outcome: nil,
            conversationID: nil, sessionID: "question-target", hostID: fixture.book.id, promptPreview: "", messagePreview: "Choose",
            workingDirectory: nil, createdAtUnixSeconds: 1_790_000_000, questionItemID: "question")
        var dismissal: CheckedContinuation<Bool, Never>?
        workspace.notificationSurfaces.register(id: UUID()) {
            await withCheckedContinuation { dismissal = $0 }
        }
        let navigation = Task { await workspace.handleCompletionNotificationTap(payload: payload) }
        defer { dismissal?.resume(returning: false); navigation.cancel() }
        try #require(await waitUntil { dismissal != nil })
        if transition == "background" { await workspace.handleScenePhaseBackground() }
        else { await workspace.handleScenePhaseInactive() }
        if transition == "reactivated" { await workspace.handleScenePhaseActive() }
        dismissal?.resume(returning: false)
        dismissal = nil
        await navigation.value
        #expect(workspace.notifications.banner == nil)
        #expect(workspace.selectedHostID == fixture.mini.id)
        #expect(book.activeSessionID == nil)
        #expect(book.questionFocusRequest == nil)
    }

    @Test(arguments: [true, false])
    func anExplicitSystemTapStartingInactiveRoutesOnlyAfterSuccessfulDismissal(_ dismissed: Bool) async throws {
        let fixture = await WorkspaceFixture(notificationApplicationIsActive: { false })
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let book = try #require(workspace.screen(for: fixture.book.id))
        let thread = try fixture.thread("system-tap", updatedAt: 1)
        await book.target.conversationList.record(thread)
        await workspace.handleScenePhaseInactive()
        workspace.notificationSurfaces.register(id: UUID()) { dismissed }
        let payload = TaskCompletionNotificationPayload(eventID: "system-tap", source: .codex, outcome: nil,
            conversationID: nil, sessionID: thread.id, hostID: fixture.book.id, promptPreview: "", messagePreview: "Choose",
            workingDirectory: nil, createdAtUnixSeconds: 1_790_000_000, questionItemID: "question")
        await workspace.handleCompletionNotificationTap(payload: payload)
        #expect(workspace.selectedHostID == (dismissed ? fixture.book.id : fixture.mini.id))
        #expect(book.activeSessionID == (dismissed ? thread.id : nil))
        #expect(book.questionFocusRequest?.itemID == (dismissed ? "question" : nil))
        #expect(workspace.notifications.banner == nil)
    }

    @Test func onlyACompletionOnScreenWithTheDrawerClosedIsSeen() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let mini = try #require(workspace.screen(for: fixture.mini.id))
        let book = try #require(workspace.screen(for: fixture.book.id))
        for (model, threadID) in [(mini, "mini-thread"), (book, "book-thread")] {
            let thread = try fixture.thread(threadID, updatedAt: 1)
            await model.target.conversationList.record(thread)
            model.resumeConversation(thread)
        }
        let later = Int64(Date.now.timeIntervalSince1970) + 1_000
        func isUnread(_ model: ChatScreenModel) throws -> Bool {
            model.target.conversationList.marks.isUnread(try #require(model.target.conversationList.threads.first))
        }
        try await finish(mini, "mini-thread", at: later)
        #expect(await waitUntil { (try? isUnread(mini)) == false })
        await mini.target.conversationList.recordTurnCompletion(threadID: "mini-thread", completedAt: later + 1)
        #expect(try isUnread(mini))

        try await finish(book, "book-thread", at: later)
        #expect(try isUnread(book))
        await workspace.handleHistoryDrawerVisibilityChanged(true, in: workspace.keyWindow)
        workspace.select(hostID: fixture.book.id)
        #expect(try isUnread(book))
        await workspace.handleHistoryDrawerVisibilityChanged(false, in: workspace.keyWindow)
        #expect(await waitUntil { (try? isUnread(book)) == false })

        await workspace.handleScenePhaseBackground()
        try await finish(book, "book-thread", at: later + 2)
        #expect(await waitUntil { book.target.conversationList.threads.first?.lastTurnCompletedAt == later + 2 })
        #expect(try isUnread(book))
        await workspace.handleScenePhaseActive()
        #expect(await waitUntil { (try? isUnread(book)) == false })
        #expect(try isUnread(mini))
    }

    @Test(arguments: [true, false])
    func anOpenHistoryPanelMarksOnlyAnUnobscuredTranscriptSeen(_ overlaysTranscript: Bool) async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let screen = try #require(workspace.screen(for: fixture.mini.id))
        let thread = try fixture.thread("sidebar-thread", updatedAt: 1)
        await screen.target.conversationList.record(thread)
        screen.resumeConversation(thread)
        await workspace.handleHistoryDrawerVisibilityChanged(true, in: workspace.keyWindow)
        screen.setPresentation(TargetPresentation(presented: true, key: true, drawerOpen: true,
                                                 drawerOverlaysTranscript: overlaysTranscript))

        let completedAt = Int64(Date.now.timeIntervalSince1970) + 1_000
        try await finish(screen, thread.id, at: completedAt)
        let session = try #require(screen.selectedConversation)
        await screen.publish(await session.snapshot())
        func isUnread() throws -> Bool {
            screen.target.conversationList.marks.isUnread(try #require(screen.target.conversationList.threads.first))
        }
        #expect(try isUnread() == overlaysTranscript)

        // A newer sidebar header is not evidence that its reply was presented.
        await screen.target.conversationList.recordTurnCompletion(threadID: thread.id, completedAt: completedAt + 1)
        screen.publishSeenCompletion()
        #expect(try isUnread())
    }

    @Test func aClaudeReplyFinishedOnScreenStaysSeenWhenItsTranscriptTimeArrives() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let thread = try fixture.thread("claude_thread", updatedAt: 1)
        await mini.target.conversationList.record(thread)
        mini.resumeConversation(thread)

        let received = Int64(Date.now.timeIntervalSince1970) + 1_000
        try await finish(mini, "claude_thread", at: received)
        #expect(await waitUntil { mini.target.conversationList.marks.marks(for: "claude_thread")?.seenThrough == received })
        await mini.target.conversationList.recordTurnCompletion(threadID: "claude_thread", completedAt: received - 1)
        let row = try #require(mini.target.conversationList.threads.first)
        #expect(row.lastTurnCompletedAt == received - 1)
        #expect(mini.target.conversationList.marks.isUnread(row) == false)
    }

    @Test func aNotificationTapOpensItsConversationBeforeRevealingTheHost() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let workspace = fixture.workspace
        let book = try #require(workspace.screen(for: fixture.book.id))
        let previous = try fixture.thread("book-previous", updatedAt: 1)
        await book.target.conversationList.record(previous)
        await book.target.conversationList.record(try fixture.thread("book-tapped", updatedAt: 2))
        book.resumeConversation(previous)
        func isPreviousUnread() throws -> Bool {
            book.target.conversationList.marks.isUnread(try #require(book.target.conversationList.threads.first { $0.id == "book-previous" }))
        }

        let later = Int64(Date.now.timeIntervalSince1970) + 1_000
        try await finish(book, "book-previous", at: later)
        #expect(await waitUntil { (try? isPreviousUnread()) == true })
        let payload = TaskCompletionNotificationPayload(
            eventID: "event-1", source: .codex, outcome: .success, conversationID: nil,
            sessionID: "book-tapped", hostID: fixture.book.id, promptPreview: "Prompt", messagePreview: "Done",
            workingDirectory: nil, createdAtUnixSeconds: TimeInterval(later)
        )
        await workspace.handleCompletionNotificationTap(payloadJSON: try String(decoding: JSONEncoder().encode(payload), as: UTF8.self))
        #expect(workspace.selectedScreen === book)
        #expect(book.activeSessionID == "book-tapped")
        #expect(try isPreviousUnread())

        book.resumeConversation(previous)
        #expect(await waitUntil { (try? isPreviousUnread()) == false })
    }

    private func finish(_ model: ChatScreenModel, _ threadID: String, at completedAt: Int64) async throws {
        await model.target.apply(gatewayEvent: try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "turn/completed",
            params: .object(["threadId": .string(threadID), "turn": .object([
                "id": .string("turn-\(completedAt)"), "status": .string("completed"), "completedAt": .number(Double(completedAt)),
            ])]),
            receivedAt: .now, sequence: nil))))
    }

}

@MainActor
struct AppSceneLifecycleTests {
    @Test func aggregateChangesOnlyWhenTheAppAsAWholeChanges() {
        let scenes = ScenePhaseAggregate()
        let first = UUID()
        let second = UUID()

        #expect(scenes.update(.active, scene: first) == .active)
        #expect(scenes.update(.active, scene: second) == nil)
        #expect(scenes.update(.background, scene: first) == nil)
        #expect(scenes.isActive)
        #expect(scenes.update(.background, scene: second) == .background)
        #expect(scenes.update(.background, scene: second) == nil)
        #expect(!scenes.isActive)
    }

    @Test func aClosedSceneStopsCountingAndTheLastOneNeverEndsTheApp() {
        let scenes = ScenePhaseAggregate()
        let first = UUID()
        let second = UUID()
        _ = scenes.update(.active, scene: first)
        _ = scenes.update(.background, scene: second)

        #expect(scenes.remove(scene: first) == .background)
        #expect(scenes.remove(scene: second) == nil)
        #expect(scenes.remove(scene: UUID()) == nil)
    }

    @Test func oneBackgroundedSceneKeepsTheWorkspaceForegroundUntilTheOtherLeavesToo() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let app = RemoteCoderAppModel(workspace: fixture.workspace, voiceCalls: TestVoiceCalls.center, scenes: ScenePhaseAggregate())
        let model = try #require(fixture.workspace.screen(for: fixture.mini.id))
        let normal = AppEnergyPolicy(isLowPowerModeEnabled: false, thermalState: .nominal)
        let first = UUID()
        let second = UUID()

        await app.apply(.active, scene: first)
        await app.apply(.active, scene: second)
        try #require(await waitUntil { model.target.shouldWarmConversations(policy: normal) })

        await app.apply(.background, scene: first)
        #expect(model.target.shouldWarmConversations(policy: normal))
        #expect(app.isApplicationActive)

        await app.apply(.background, scene: second)
        #expect(!model.target.shouldWarmConversations(policy: normal))
        #expect(!app.isApplicationActive)
    }

    @Test func activatingTheAppReconcilesTheCurrentHosts() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let app = RemoteCoderAppModel(workspace: fixture.workspace, voiceCalls: TestVoiceCalls.center, scenes: ScenePhaseAggregate())
        let book = try #require(fixture.workspace.screen(for: fixture.book.id))

        fixture.workspace.settings.delete(fixture.book)
        #expect(!book.isRetired)

        await app.apply(.active, scene: UUID())

        #expect(book.isRetired)
    }
}

@MainActor
private func withCheckpointWriterLock(_ file: URL, operation: () async throws -> Void) async throws {
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
    guard result == SQLITE_OK, let opened else {
        let detail = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the checkpoint writer fixture."
        if let opened { sqlite3_close(opened) }
        throw CheckpointDatabase.Failure(operation: "open competing writer", code: result, detail: detail)
    }
    defer { sqlite3_close(opened) }
    let locked = sqlite3_exec(opened, "BEGIN IMMEDIATE", nil, nil, nil)
    guard locked == SQLITE_OK else {
        throw CheckpointDatabase.Failure(operation: "lock competing writer", code: locked, detail: String(cString: sqlite3_errmsg(opened)))
    }
    defer { sqlite3_exec(opened, "ROLLBACK", nil, nil, nil) }
    try await operation()
}

@MainActor
private final class NotificationReadGate {
    private var continuation: CheckedContinuation<ConversationHeader, Never>?
    var isWaiting: Bool { continuation != nil }

    func read() async -> ConversationHeader {
        await withCheckedContinuation { continuation = $0 }
    }

    func release(_ thread: ConversationHeader) {
        continuation?.resume(returning: thread)
        continuation = nil
    }
}

enum WarmingBlocker: CaseIterable, Sendable {
    case lowPower, seriousThermalState, hidden, inactiveScene, retired
}

fileprivate extension ConversationIndex {
    func holdAdmissionLookup(entered: TestFlag, release: DispatchSemaphore) -> Bool {
        entered.value = true
        return release.wait(timeout: .now() + 10) == .success
    }
}

@MainActor
private final class AdmissionLifecycleSink: GatewayEventSink {
    private let target: ChatTargetModel
    private(set) var connected = false
    private(set) var delivering = false
    private(set) var finished = false

    init(target: ChatTargetModel) { self.target = target }

    var isRetired: Bool { target.isRetired }
    var acceptsGatewayEvents: Bool { target.acceptsGatewayEvents }
    var acceptsConnectionReports: Bool { true }

    func apply(gatewayEvent event: RoutedGatewayEvent, replay: Bool) async {
        delivering = true
        await target.apply(gatewayEvent: event, replay: replay)
        finished = true
    }

    func gatewayConnectionChanged(_ link: GatewayEventPump.Link, connection: UUID?) { connected = link == .connected }
    func gatewayConnectivityChanged(_ connectivity: GatewayConnectivity) {}
    func gatewayNetworkPathChanged() {}
    func gatewayActivityRefreshRequested() {}
    func gatewayThreadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {}
    func gatewayQuestionsChanged(_ change: ServerNotification.QuestionsChanged) {}
    func defersReplay(_ event: RoutedGatewayEvent) -> Bool { false }
    func reconcile(gap: ReplayProgress.Gap) async {}
}
