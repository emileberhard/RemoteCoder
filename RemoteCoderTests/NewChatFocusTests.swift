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
        let controller = UIHostingController(rootView: ChatRootView(workspace: fixture.workspace, sceneValue: .constant(nil))
            .environment(fixture.workspace.settings)
            .environment(fixture.workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active)
            .environment(\.horizontalSizeClass, .compact))
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close() }
        #expect(await waitUntil { fixture.workspace.keyWindow.isAttached && fixture.workspace.events.keyScreenID != nil })

        fixture.workspace.events.receive(.open(.newChat(slot: UUID())))
        try #require(await waitUntil { hasComposerFirstResponder(in: controller.view) },
            "The real New Chat event must be able to focus the native composer before testing cancellation")
        controller.view.endEditing(true)
        try #require(await waitUntil { !hasComposerFirstResponder(in: controller.view) })

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
            try #require(activateElement(identifier: "open-conversations", in: controller.view),
                "The header's Conversations button must open the drawer")
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

    private func activateElement(identifier: String, in element: Any) -> Bool {
        guard let object = element as? NSObject else { return false }
        if (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier {
            return object.accessibilityActivate()
        }
        let elements = object.accessibilityElements
            ?? (0..<max(object.accessibilityElementCount(), 0)).compactMap { object.accessibilityElement(at: $0) }
        let children = elements + ((object as? UIView)?.subviews ?? [])
        return children.contains { activateElement(identifier: identifier, in: $0) }
    }

    private func hasComposerFirstResponder(in view: UIView) -> Bool {
        (view.accessibilityIdentifier == "codex-composer-input" && view.isFirstResponder)
            || view.subviews.contains(where: hasComposerFirstResponder)
    }
}
