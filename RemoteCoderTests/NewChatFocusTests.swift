import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct NewChatFocusTests {
    enum Navigation: Sendable { case drawer, host, newChat, selectionMirror }

    @Test(arguments: [Navigation.drawer, .host, .newChat, .selectionMirror])
    func newChatFocusRespectsNavigation(navigation: Navigation) async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let commands = SceneCommands()
        let controller = UIHostingController(rootView: ChatRootView(workspace: fixture.workspace, sceneValue: .constant(nil))
            .environment(fixture.workspace.settings)
            .environment(fixture.workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active)
            .environment(\.horizontalSizeClass, .compact)
            .overlay { SceneCommandObserver(commands: commands) })
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close(); commands.actions = nil }
        #expect(await waitUntil { fixture.workspace.keyWindow.isAttached && fixture.workspace.events.keyScreenID != nil })

        fixture.workspace.events.receive(.open(.newChat(slot: UUID())))
        try #require(await waitUntil { hasComposerFirstResponder(in: controller.view) },
            "The real New Chat event must be able to focus the native composer before testing cancellation")
        controller.view.endEditing(true)
        try #require(await waitUntil { !hasComposerFirstResponder(in: controller.view) })

        var drawerAction: ChatWindowActions?
        if case .drawer = navigation {
            try #require(await waitUntil {
                guard let actions = commands.actions, actions.isEnabled(.toggleSidebar) else { return false }
                drawerAction = actions
                return true
            }, "The focused scene must publish its real drawer command before queuing focus")
        }

        let before = try #require(fixture.workspace.selectedScreen).transcriptIdentity
        fixture.workspace.events.receive(.open(.newChat(slot: UUID())))
        try #require(fixture.workspace.selectedScreen?.transcriptIdentity != before)
        let request = try #require(fixture.workspace.keyWindow.composerFocusCompletion)
        let completed = TestFlag()
        let completion = Task {
            await request.value
            completed.value = true
        }
        defer { request.cancel(); completion.cancel() }
        switch navigation {
        case .drawer:
            let actions = try #require(drawerAction)
            actions.run(.toggleSidebar)
            #expect(await waitUntil { fixture.workspace.keyWindow.isHistoryDrawerOpen })
        case .host:
            fixture.workspace.select(hostID: fixture.book.id)
        case .newChat:
            let button = try #require(findButton(in: controller.view, identifier: "new-chat"))
            button.sendActions(for: .primaryActionTriggered)
        case .selectionMirror:
            fixture.workspace.syncSelection()
        }

        try #require(await waitUntil { completed.value }, "The captured focus request must complete")
        switch navigation {
        case .selectionMirror:
            #expect(!request.isCancelled)
            #expect(await waitUntil { hasComposerFirstResponder(in: controller.view) },
                "Mirroring the selected host must preserve its intended New Chat focus")
        case .drawer, .host, .newChat:
            #expect(request.isCancelled)
            #expect(!hasComposerFirstResponder(in: controller.view),
                "An earlier New Chat must not reopen the keyboard after later navigation")
        }
    }

    private func findButton(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0, identifier: identifier) }.first
    }

    private final class SceneCommands {
        var actions: ChatWindowActions?
    }

    private struct SceneCommandObserver: View {
        let commands: SceneCommands
        @FocusedValue(\.chatWindowActions) private var actions

        var body: some View {
            Color.clear.frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onChange(of: actions, initial: true) { _, actions in commands.actions = actions }
        }
    }

    private func hasComposerFirstResponder(in view: UIView) -> Bool {
        (view.accessibilityIdentifier == "codex-composer-input" && view.isFirstResponder)
            || view.subviews.contains(where: hasComposerFirstResponder)
    }
}
