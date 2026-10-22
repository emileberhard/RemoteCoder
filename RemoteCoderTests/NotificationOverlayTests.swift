import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct NotificationOverlayTests {
    @Test func aRefusedUIKitDismissalReturnsAtItsDeadline() async {
        let presenter = RefusingPresenter()
        #expect(await !CompletionNotificationOverlay.Attachment.dismissPresentations(from: presenter, timeout: .milliseconds(50)))
    }

    private final class RefusingPresenter: UIViewController {
        private let modal = UIViewController()
        override var presentedViewController: UIViewController? { modal }
        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {}
    }

    @Test(arguments: [UIModalPresentationStyle.pageSheet, .fullScreen])
    func aBannerRendersAboveModalContentWithoutTakingKeyboardFocus(style: UIModalPresentationStyle) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let originalKey = scene.keyWindow
        let previousWindows = Set(scene.windows.map(ObjectIdentifier.init))
        let owner = UIWindow(windowScene: scene)
        let presentation = ModalState()
        let root = UIHostingController(rootView: ModalRoot(workspace: fixture.workspace,
            presentation: presentation, fullScreen: style == .fullScreen).environment(AppThemeStore()))
        owner.rootViewController = root
        owner.isHidden = false
        defer {
            root.dismiss(animated: false)
            owner.isHidden = true
            owner.rootViewController = nil
        }
        try #require(await waitUntil { scene.windows.contains { $0 is CompletionBannerWindow && !previousWindows.contains(ObjectIdentifier($0)) } })
        let banner = try #require(scene.windows.compactMap { $0 as? CompletionBannerWindow }
            .first { !previousWindows.contains(ObjectIdentifier($0)) })
        #expect(banner.isHidden)
        presentation.isPresented = true
        try #require(await waitUntil { root.presentedViewController?.view.window != nil })
        let modal = try #require(root.presentedViewController)
        let options = await RemoteCoderAppDelegate.foregroundNotificationOptions(
            userInfo: [:], title: "Root task finished", body: "Ready to inspect",
            applicationIsActive: { true }, workspace: fixture.workspace
        )
        #expect(options.isEmpty)
        try #require(await waitUntil { !banner.isHidden && !banner.bannerBounds.isEmpty })
        #expect(root.presentedViewController === modal)
        #expect(banner.windowLevel > (modal.view.window?.windowLevel ?? owner.windowLevel))
        #expect(!banner.isKeyWindow)
        #expect(scene.keyWindow === originalKey)
        #expect(banner.point(inside: CGPoint(x: banner.bannerBounds.midX, y: banner.bannerBounds.midY), with: nil))
        #expect(!banner.point(inside: CGPoint(x: 1, y: banner.bounds.maxY - 1), with: nil))
        fixture.workspace.notifications.dismiss()
        #expect(await waitUntil { banner.isHidden && banner.bannerBounds.isEmpty })
        fixture.workspace.notifications.present(.init(isConversationAlert: false, title: "Next task finished",
            body: "Ready again", payload: nil, decodingFailure: nil))
        #expect(await waitUntil { !banner.isHidden && !banner.bannerBounds.isEmpty })
        #expect(!banner.isKeyWindow)
        fixture.workspace.notifications.dismiss()
        #expect(await waitUntil { banner.isHidden && banner.bannerBounds.isEmpty })
        let target = try #require(fixture.workspace.screen(for: fixture.book.id))
        let thread = try fixture.thread("modal-target", updatedAt: 1)
        await target.target.conversationList.record(thread)
        let question = TaskCompletionNotificationPayload(eventID: "question:modal-target:q", source: .codex,
            outcome: nil, conversationID: nil, sessionID: thread.id, hostID: fixture.book.id,
            promptPreview: "Question", messagePreview: "Choose", workingDirectory: nil,
            createdAtUnixSeconds: 1_790_000_000, questionItemID: "q")
        // This is the same workspace action the banner button calls. Its
        // registered scene dismisses the cover before committing question focus.
        await fixture.workspace.handleCompletionNotificationTap(payload: question)
        #expect(root.presentedViewController == nil)
        // UIKit dismissal must also reset SwiftUI's binding, or Voice Mode and
        // Settings can remain logically presented after navigation.
        #expect(await waitUntil { !presentation.isPresented })
        #expect(fixture.workspace.selectedHostID == fixture.book.id)
        #expect(target.activeSessionID == thread.id)
        #expect(target.questionFocusRequest?.itemID == "q")
    }

    @Observable final class ModalState {
        var isPresented = false
    }

    private struct ModalRoot: View {
        let workspace: ChatWorkspaceModel
        @Bindable var presentation: ModalState
        let fullScreen: Bool

        var body: some View {
            Group {
                if fullScreen {
                    Text("Workspace").fullScreenCover(isPresented: $presentation.isPresented) {
                        Text("Voice surface")
                    }
                } else {
                    Text("Workspace").sheet(isPresented: $presentation.isPresented) {
                        Text("Settings surface")
                    }
                }
            }
            .background { CompletionNotificationOverlay(workspace: workspace) }
        }
    }
}
