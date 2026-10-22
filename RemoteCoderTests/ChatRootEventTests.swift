import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct ChatRootEventTests {
    enum RootState: Sendable { case loading, retirementFailure }
    enum Entry: Sendable { case quickAction, newChatLink }
    enum Supersession: Sendable { case cancellation, navigation }

    @Test
    func navigationAfterPreparationWinsBeforeOpeningConsumption() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachWindow(opening: nil)
        defer { workspace.detachWindow(window) }
        let mini = try #require(workspace.model(for: fixture.mini.id))
        let book = try #require(window.screen(for: .init(hostID: fixture.book.id)))
        book.activeConversation = try fixture.thread("book-open", updatedAt: 20)
        let address = ConversationAddress(hostID: fixture.book.id, threadID: "book-open")
        window.removeScreen(for: mini.target)
        let generation = workspace.navigationGeneration
        let event = ExternalEvent.quickAction(.init(action: .newChat))
        try await workspace.prepareWindowForExternalEvent(event, in: window, admittedGeneration: generation)
        let prepared = ChatOpeningEvent.admitted(event, generation)

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
    func anInitialWindowValueReachesTheNativeComposer() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let slot = UUID()
        let controller = UIHostingController(rootView: ChatRootView(workspace: fixture.workspace, sceneValue: .constant(.newChat(slot: slot)))
            .environment(fixture.workspace.settings)
            .environment(fixture.workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active)
            .environment(\.horizontalSizeClass, .compact))
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close() }

        #expect(await waitUntil { composer(in: controller.view)?.isFirstResponder == true })
        #expect(fixture.workspace.keyWindow.id == slot)
    }

    @Test
    func anEndedVoiceCallsPresentationIsDroppedWithoutOpeningAChat() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachWindow(opening: nil)
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
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachWindow(opening: nil)
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

    @Test(arguments: [RootState.loading, .retirementFailure], [Entry.quickAction, .newChatLink])
    func newChatRoutesWhileTheRootHasNoSelectedScreen(state: RootState, entry: Entry) async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
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
        let controller = UIHostingController(rootView: ChatRootView(workspace: workspace, sceneValue: .constant(nil))
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
        let event: ExternalEvent = switch entry {
        case .quickAction: .quickAction(.init(action: .newChat))
        case .newChatLink: .open(.newChat(slot: UUID()))
        }
        workspace.events.receive(event)

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
