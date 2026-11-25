import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct ChatRootEventTests {
    enum RootState: Sendable { case loading, retirementFailure }
    enum Supersession: Sendable { case cancellation, navigation }

    @Test
    func navigationAfterPreparationWinsBeforeOpeningConsumption() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachMainWindow()
        defer { workspace.detachWindow(window) }
        let mini = try #require(workspace.model(for: fixture.mini.id))
        let book = try #require(window.screen(for: .init(hostID: fixture.book.id)))
        book.activeConversation = try fixture.thread("book-open", updatedAt: 20)
        let address = ConversationAddress(hostID: fixture.book.id, threadID: "book-open")
        window.removeScreen(for: mini.target)
        let generation = workspace.navigationGeneration
        let event = ExternalEvent.quickAction(.init(action: .newChat))
        try await workspace.prepareWindowForExternalEvent(event, in: window, admittedGeneration: generation)
        let prepared = ChatOpeningEvent(event: event, generation: generation)

        workspace.selectConversation(at: address)
        var performed = false
        prepared.performIfCurrent(in: window, navigationGeneration: workspace.navigationGeneration) { _ in
            performed = true
            _ = workspace.startNewConversation(onHostID: mini.hostID)
        }

        #expect(!performed)
        #expect(workspace.isShowingConversation(at: address, on: window.selectedScreen))
    }

    @Test
    func conversationDeepLinkSwitchesInTheSameWindowAndReportsUnknownHosts() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: ChatRootView(workspace: workspace)
            .environment(workspace.settings)
            .environment(workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active)
            .environment(\.horizontalSizeClass, .compact))
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close() }
        try #require(await waitUntil { workspace.keyWindow.isAttached && workspace.events.keyScreenID == workspace.keyWindow.id })

        let window = workspace.keyWindow
        let book = try #require(window.screen(for: .init(hostID: fixture.book.id)))
        book.activeConversation = try fixture.thread("book-linked", updatedAt: 20)
        let address = ConversationAddress(hostID: fixture.book.id, threadID: "book-linked")
        let link = RemoteCoderDeepLinks.url(for: RemoteCoderConversationLink(hostID: fixture.book.id, threadID: "book-linked"))

        #expect(workspace.openDeepLink(link))
        #expect(await waitUntil { workspace.isShowingConversation(at: address, on: window.selectedScreen) })
        #expect(workspace.keyWindow === window)
        #expect(workspace.externalEventError == nil)

        let unknownHostLink = RemoteCoderDeepLinks.url(for: RemoteCoderConversationLink(hostID: UUID(), threadID: "missing"))
        #expect(workspace.openDeepLink(unknownHostLink))
        #expect(workspace.externalEventError != nil)

        let nonAppURL = try #require(URL(string: "https://example.com"))
        #expect(!workspace.openDeepLink(nonAppURL))
    }

    @Test
    func notificationAndDeferredSwitchCommitIntoMainWindowEvenWhenQuickEntryTakesFocus() async throws {
        var headerContinuation: CheckedContinuation<ConversationHeader, Error>?
        var headerReadStarted = false
        let fixture = await WorkspaceFixture(loadConversationHeader: { _, _ in
            try await withCheckedThrowingContinuation { continuation in
                headerReadStarted = true
                headerContinuation = continuation
            }
        })
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let main = workspace.attachMainWindow()
        defer { workspace.detachWindow(main) }
        let mainMini = try #require(main.screen(for: .init(hostID: fixture.mini.id)))
        let chatA = try fixture.thread("chat-a", updatedAt: 10)
        let chatB = try fixture.thread("chat-b", updatedAt: 20)
        let chatC = try fixture.thread("chat-c", updatedAt: 30)
        mainMini.activeConversation = chatA
        await mainMini.target.conversationList.record(chatC)

        let notificationTask = Task {
            await workspace.handleCompletionNotificationTap(
                payload: TaskCompletionNotificationPayload(
                    eventID: "completion:chat-b",
                    source: .codex,
                    outcome: nil,
                    conversationID: nil,
                    sessionID: "chat-b",
                    hostID: fixture.mini.id,
                    promptPreview: "Done",
                    messagePreview: "Ready",
                    workingDirectory: nil,
                    createdAtUnixSeconds: 1_790_000_000,
                    questionItemID: nil
                ),
                in: main
            )
        }
        try #require(await waitUntil { headerReadStarted })

        let quickEntry = workspace.attachDraftWindow(slot: UUID())
        defer { workspace.detachWindow(quickEntry) }
        let quickEntryScreen = try #require(quickEntry.selectedScreen)
        try #require(await quickEntryScreen.prepareDraft())
        quickEntryScreen.input = "QuickEntry draft"
        workspace.setWindowKey(quickEntry)
        #expect(workspace.keyWindow === quickEntry)

        headerContinuation?.resume(returning: chatB)
        await notificationTask.value

        #expect(workspace.isShowingConversation(at: ConversationAddress(hostID: fixture.mini.id, threadID: "chat-b"),
                                                on: main.selectedScreen))
        #expect(quickEntry.selectedScreen?.activeSessionID == nil)
        #expect(quickEntryScreen.input == "QuickEntry draft")

        let addressC = ConversationAddress(hostID: fixture.mini.id, threadID: "chat-c")
        #expect(workspace.switchConversation(to: addressC, in: main) == .changed)
        #expect(await waitUntil { workspace.isShowingConversation(at: addressC, on: main.selectedScreen) })
        #expect(quickEntry.selectedScreen?.activeSessionID == nil)
        #expect(quickEntryScreen.input == "QuickEntry draft")
    }

    @Test
    func newChatFromRouterTargetsMainWindowWithoutDisturbingQuickEntry() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: ChatRootView(workspace: workspace)
            .environment(workspace.settings)
            .environment(workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active)
            .environment(\.horizontalSizeClass, .compact))
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close() }
        try #require(await waitUntil { workspace.keyWindow.isAttached && workspace.events.keyScreenID == workspace.keyWindow.id })

        let main = workspace.keyWindow
        let mainMini = try #require(main.screen(for: .init(hostID: fixture.mini.id)))
        mainMini.resumeConversation(try fixture.thread("chat-a", updatedAt: 10))
        try #require(mainMini.activeSessionID == "chat-a")

        let quickEntry = workspace.attachDraftWindow(slot: UUID())
        defer { workspace.detachWindow(quickEntry) }
        let quickEntryScreen = try #require(quickEntry.selectedScreen)
        try #require(await quickEntryScreen.prepareDraft())
        let quickEntryDraftID = quickEntryScreen.newChatDraftID
        quickEntryScreen.input = "QuickEntry draft"
        workspace.setWindowKey(quickEntry)
        #expect(workspace.keyWindow === quickEntry)

        workspace.events.receive(.quickAction(.init(action: .newChat)))

        #expect(await waitUntil { main.selectedScreen?.activeSessionID == nil })
        #expect(quickEntryScreen.newChatDraftID == quickEntryDraftID)
        #expect(quickEntryScreen.input == "QuickEntry draft")
    }

    @Test
    func closingAndReopeningMainWindowCancelsPendingNotificationCommit() async throws {
        var headerContinuation: CheckedContinuation<ConversationHeader, Error>?
        var headerReadStarted = false
        let fixture = await WorkspaceFixture(loadConversationHeader: { _, _ in
            try await withCheckedThrowingContinuation { continuation in
                headerReadStarted = true
                headerContinuation = continuation
            }
        })
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let main = workspace.attachMainWindow()
        defer { workspace.detachWindow(main) }
        let mainMini = try #require(main.screen(for: .init(hostID: fixture.mini.id)))
        let chatA = try fixture.thread("chat-a", updatedAt: 10)
        let chatB = try fixture.thread("chat-b", updatedAt: 20)
        mainMini.activeConversation = chatA

        let notificationTask = Task {
            await workspace.handleCompletionNotificationTap(
                payload: TaskCompletionNotificationPayload(
                    eventID: "completion:chat-b",
                    source: .codex,
                    outcome: nil,
                    conversationID: nil,
                    sessionID: "chat-b",
                    hostID: fixture.mini.id,
                    promptPreview: "Done",
                    messagePreview: "Ready",
                    workingDirectory: nil,
                    createdAtUnixSeconds: 1_790_000_000,
                    questionItemID: nil
                ),
                in: main
            )
        }
        try #require(await waitUntil { headerReadStarted })

        workspace.detachWindow(main)
        let reopened = workspace.attachMainWindow()
        #expect(reopened === main)

        headerContinuation?.resume(returning: chatB)
        await notificationTask.value

        #expect(workspace.isShowingConversation(at: ConversationAddress(hostID: fixture.mini.id, threadID: "chat-a"),
                                                on: reopened.selectedScreen))
    }

    @Test
    func anEndedVoiceCallsPresentationIsDroppedWithoutOpeningAChat() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachMainWindow()
        defer { workspace.detachWindow(window) }
        let mini = try #require(workspace.model(for: fixture.mini.id))
        window.removeScreen(for: mini.target)
        #expect(window.selectedScreen == nil)
        let endedCall = UUID()

        await #expect(throws: CancellationError.self) {
            try await workspace.prepareWindowForExternalEvent(.presentVoiceCall(endedCall), in: window,
                admittedGeneration: workspace.navigationGeneration)
        }
        #expect(!workspace.selectLiveVoiceCall(endedCall))
        #expect(window.selectedScreen == nil)
    }

    @Test(arguments: [Supersession.cancellation, .navigation])
    func aSupersededQueuedEventCannotCancelANewerConversationSwitch(supersession: Supersession) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachMainWindow()
        defer { workspace.detachWindow(window) }
        let mini = try #require(workspace.model(for: fixture.mini.id))
        let book = try #require(window.screen(for: .init(hostID: fixture.book.id)))
        book.activeConversation = try fixture.thread("book-open", updatedAt: 20)
        let address = ConversationAddress(hostID: fixture.book.id, threadID: "book-open")
        window.removeScreen(for: mini.target)
        #expect(window.selectedScreen == nil)
        let admittedGeneration = workspace.navigationGeneration
        let event = Task { @MainActor in
            #expect(workspace.switchConversation(to: address) == .changed)
            do {
                try await workspace.prepareWindowForExternalEvent(.quickAction(.init(action: .newChat)), in: window,
                    admittedGeneration: admittedGeneration)
                return false
            } catch is CancellationError { return true }
            catch { Issue.record("Unexpected event preparation failure: \(error)"); return false }
        }
        if case .cancellation = supersession { event.cancel() }

        #expect(await event.value)
        #expect(await waitUntil { workspace.isShowingConversation(at: address, on: window.selectedScreen) },
            "A superseded queued event must leave the newer conversation switch intact")
    }

    @Test(arguments: [RootState.loading, .retirementFailure])
    func newChatRoutesWhileTheRootHasNoSelectedScreen(state: RootState) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.keyWindow
        let target = try #require(workspace.model(for: fixture.mini.id))
        let screen = try #require(workspace.selectedScreen)
        try #require(await screen.prepareDraft())
        let directory = fixture.temporaryStorage.storage.directory(for: .target(hostID: fixture.mini.id)).appending(path: "drafts")
        let conflictingID = UUID()
        if case .loading = state { window.removeScreen(for: target.target) }
        if case .retirementFailure = state {
            try #require(await target.drafts.flush())
            let draft = try #require(await target.drafts.draft(for: screen.newChatDestination))
            try await writeConflictingDraft(id: conflictingID, destination: draft.destination, directory: directory)
            screen.input = "Keep this failed target's draft"
        }
        defer {
            if case .retirementFailure = state {
                do {
                    try await writeConflictingDraft(id: conflictingID, destination: "thread:other-owner", directory: directory)
                    workspace.retryDraftRetirement(target.target)
                    #expect(await workspace.finishHostChanges())
                } catch { Issue.record("Could not recover the retirement fixture: \(error)") }
            }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: ChatRootView(workspace: workspace)
            .environment(workspace.settings)
            .environment(workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active)
            .environment(\.horizontalSizeClass, .compact))
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close() }
        try #require(await waitUntil { window.isAttached })
        if case .retirementFailure = state {
            var changed = fixture.mini
            changed.port = 3
            #expect(workspace.settings.upsert(changed))
            workspace.reconcileHosts()
            #expect(await workspace.finishHostChanges() == false)
            try #require(await waitUntil { composer(in: controller.view) == nil })
        }
        #expect(window.selectedScreen == nil)
        #expect(await waitUntil { workspace.events.keyScreenID == window.id })
        workspace.events.receive(.quickAction(.init(action: .newChat)))

        #expect(await waitUntil { composer(in: controller.view)?.isFirstResponder == true },
            "A real New Chat event must reach the native composer while the root has no selected screen")
        #expect(window.selectedScreen != nil)
        if case .retirementFailure = state {
            #expect(window.selectedScreen?.hostID == fixture.book.id)
            #expect(workspace.draftRetirementFailure(for: target.target)?.target == target.target)
        }
    }

    private func composer(in root: UIView) -> UITextView? {
        if let input = root as? UITextView, input.accessibilityIdentifier == "codex-composer-input" { return input }
        return root.subviews.lazy.compactMap { composer(in: $0) }.first
    }
}
