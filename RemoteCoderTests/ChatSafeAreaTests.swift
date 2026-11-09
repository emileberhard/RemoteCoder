import Combine
import QuickLook
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct ChatSafeAreaTests {
    @Test(arguments: [false, true])
    func emptyChatKeepsDeviceInsetsAcrossFeedbackAndPresentation(haptics: Bool) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView:
            ChatRootView(workspace: fixture.workspace, sceneValue: .constant(nil))
                .environment(fixture.workspace.settings)
                .environment(fixture.workspace.modelPickerPreferences)
                .environment(AppThemeStore())
                .environment(\.scenePhase, .active)
                .environment(\.horizontalSizeClass, .compact)
                .background {
                    if haptics { HapticAttachment(service: feedback.service, voiceCall: TestVoiceCalls.center.call) }
                }
        )
        hosted.show(controller)
        defer { controller.view.endEditing(true); hosted.close() }
        try #require(await waitUntil { composer(in: controller.view) != nil })
        let window = try #require(controller.view.window)
        let initial = window.safeAreaInsets
        try #require(initial.top > 0 && initial.bottom > 0)
        inspect(controller, label: "initial", expected: initial)
        for event in HapticEvent.allCases { feedback.service.play(event) }
        inspect(controller, label: "feedback", expected: initial)
        try await rotate(scene, to: .landscapeRight)
        inspect(controller, label: "landscape", expected: window.safeAreaInsets)
        try await rotate(scene, to: .portrait)
        inspect(controller, label: "portrait-restored", expected: initial)
        let cover = UIHostingController(rootView: Color.blue.ignoresSafeArea())
        cover.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            controller.present(cover, animated: false) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            cover.dismiss(animated: false) { continuation.resume() }
        }
        inspect(controller, label: "dismiss-cover", expected: initial)
        let screen = try #require(fixture.workspace.selectedScreen)
        let opener = screen.target.fileOpener
        defer { opener.invalidate() }
        let origin = HostFileOrigin(hostID: screen.hostID, conversationID: screen.currentConversationID,
            transcriptID: screen.transcriptIdentity, workingDirectory: nil, hostName: "Fixture", presentationScope: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        opener.open(EmbeddedFileRequest(dataURL: "data:image/png;base64,\(png)", suggestedName: "Layout"),
            origin: origin, frame: nil)
        await opener.operation?.value
        try #require(await waitUntil { presented(in: controller) is QLPreviewController })
        try #require(await waitUntil { presented(in: controller)?.isBeingPresented == false })
        try await rotate(scene, to: .landscapeLeft)
        try await rotate(scene, to: .portrait)
        opener.suspendPresentation()
        try #require(await waitUntil { presented(in: controller) == nil })
        inspect(controller, label: "dismiss-quick-look", expected: initial)
        let threadID = "claude_44444444-0000-0000-0000-000000000004"
        screen.selectDraft(.thread(threadID))
        try #require(await screen.prepareDraft())
        screen.setActiveSessionID(threadID)
        let session = await screen.target.conversations.session(conversationID: screen.currentConversationID, threadID: threadID)
        await screen.adopt(session)
        let gateway = HistoryGatewayFixture(threadID: threadID)
        await gateway.setHistory(.init(entries: (0..<10).map { index in
            .init(turnId: "t\(index)", item: .agentMessage(id: "m\(index)", text: "Message \(index)"),
                startedAtOrdinal: Int64(index), isComplete: true)
        }, turns: []))
        let history = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(
            directory: fixture.temporaryStorage.storage.root.appending(path: "layout-history")))
        let read = await session.beginHistoryRead()
        let tail = try await history.openTail(header: gateway.header, base: read.base)
        await screen.applyConversationSnapshot(tail, read: read, from: session, source: "fixture")
        try #require(!screen.messages.isEmpty)
        inspect(controller, label: "populated", expected: initial)
        _ = fixture.workspace.startNewConversation(onHostID: fixture.mini.id)
        try #require(await waitUntil { screen.streamItems.isEmpty })
        inspect(controller, label: "populated-to-empty", expected: initial)
        let input = try #require(composer(in: controller.view))
        var keyboardShown = false
        var keyboardHidden = false
        let shown = NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            .sink { _ in keyboardShown = true }
        let hidden = NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)
            .sink { _ in keyboardHidden = true }
        defer { shown.cancel(); hidden.cancel() }
        let restingFrame = input.convert(input.bounds, to: window)
        input.becomeFirstResponder()
        try #require(await waitUntil { keyboardShown })
        keyboardHidden = false
        input.resignFirstResponder()
        try #require(await waitUntil { keyboardHidden })
        try #require(await waitUntil {
            controller.view.layoutIfNeeded()
            return input.convert(input.bounds, to: window) == restingFrame
        })
        inspect(controller, label: "keyboard-hidden", expected: initial)
        for _ in 0..<20 {
            _ = fixture.workspace.startNewConversation(onHostID: fixture.mini.id)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
        }
        inspect(controller, label: "new-chats", expected: initial)
    }

    @Test
    func diagnosticsCaptureCollapsedGeometryWithConversationAndNativeIdentities() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: Color.clear)
        hosted.show(host)
        defer { hosted.close() }
        let window = try #require(host.view.window)
        host.view.layoutIfNeeded()
        let chat = fixture.workspace.attachWindow(opening: nil)
        defer { fixture.workspace.detachWindow(chat) }
        let context = ChatLayoutContext(window: chat)
        #expect(ChatLayoutContext(window: nil).description.contains("thread=unknown"))
        var records: [String] = []
        let recorder = ChatLayoutRecorder(log: { records.append($0) })
        recorder.start(context: context)
        defer { recorder.stop() }
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let rootInsets = EdgeInsets(top: window.safeAreaInsets.top, leading: window.safeAreaInsets.left,
            bottom: window.safeAreaInsets.bottom, trailing: window.safeAreaInsets.right)
        recorder.geometry(.init(frame: CGRect(origin: .zero, size: safe.size), insets: rootInsets), context: context)
        recorder.verticalPosition("header", safe.minY)
        recorder.verticalPosition("composer", safe.maxY)
        try #require(await waitUntil { records.contains { $0.contains("event=geometry[") } })
        let before = try #require(records.last)
        #expect(before.contains("headerOutsideSafeArea=false composerOutsideSafeArea=false"))
        #expect(before.contains("geometryPending=false"))
        #expect(before.contains("header={ageMs="))
        #expect(before.contains("thread=new-chat"))
        #expect(before.contains("chatWindow=\(chat.id.uuidString)"))
        #expect(before.contains("window=\(ObjectIdentifier(window))"))
        #expect(before.contains("UIHostingController@\(ObjectIdentifier(host))"))
        let unchanged = records.count
        recorder.verticalPosition("header", safe.minY)
        recorder.contextChanged(context)
        try await Task.sleep(for: .milliseconds(250))
        #expect(records.count == unchanged)
        recorder.geometry(.init(frame: window.bounds, insets: EdgeInsets()), context: nil)
        recorder.verticalPosition("header", 0)
        recorder.verticalPosition("composer", window.bounds.maxY)
        try #require(await waitUntil { records.contains { $0.contains("headerOutsideSafeArea=true composerOutsideSafeArea=true") } })
        let collapsed = try #require(records.last)
        #expect(collapsed.contains("safe=\(window.safeAreaInsets.top),"))
        #expect(collapsed.contains("orientation=\(scene.effectiveGeometry.interfaceOrientation.rawValue)"))
        #expect(records.count == unchanged + 1)
    }

    @Test
    func movingChatDoesNotPublishGeometryChanges() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        var records: [String] = []
        let recorder = ChatLayoutRecorder(log: { records.append($0) })
        let context = ChatLayoutContext(window: nil)
        recorder.start(context: context)
        defer { recorder.stop() }
        let controller = UIHostingController(rootView: GeometryProbe(offset: .zero, recorder: recorder))
        hosted.show(controller)
        defer { hosted.close() }
        try #require(await waitUntil { records.contains { $0.contains("event=geometry[") } })
        let initial = records.count
        for x in stride(from: 20, through: 300, by: 20) {
            controller.rootView = GeometryProbe(offset: CGSize(width: CGFloat(x), height: 0), recorder: recorder)
            controller.view.layoutIfNeeded()
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(records.count == initial, "Unexpected records: \(records.dropFirst(initial))")
    }

    @Test
    func verticallyDisplacedChatReportsHeaderOutsideSafeArea() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        var records: [String] = []
        let recorder = ChatLayoutRecorder(log: { records.append($0) })
        recorder.start(context: ChatLayoutContext(window: nil))
        defer { recorder.stop() }
        let controller = UIHostingController(rootView: GeometryProbe(offset: .zero, recorder: recorder))
        hosted.show(controller)
        defer { hosted.close() }
        try #require(await waitUntil { records.contains { $0.contains("event=geometry[") } })
        #expect(records.last?.contains("headerOutsideSafeArea=false") == true)
        controller.rootView = GeometryProbe(offset: CGSize(width: 0, height: -100), recorder: recorder)
        controller.view.layoutIfNeeded()
        try #require(await waitUntil {
            records.last?.contains("headerOutsideSafeArea=true") == true
        })
    }

    private struct GeometryProbe: View {
        let offset: CGSize
        let recorder: ChatLayoutRecorder

        var body: some View {
            VStack {
                Color.clear.frame(height: 44).chatLayoutDiagnostics("header")
                Spacer()
                Color.clear.frame(height: 60).chatLayoutDiagnostics("composer")
            }
            .offset(offset)
            .environment(\.chatLayoutRecorder, recorder)
        }
    }

    private func rotate(_ scene: UIWindowScene, to orientation: UIInterfaceOrientation) async throws {
        let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait : orientation == .landscapeRight ? .landscapeRight : .landscapeLeft
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in Issue.record(error) }
        try #require(await waitUntil { scene.effectiveGeometry.interfaceOrientation == orientation })
        try #require(await waitUntil { scene.windows.filter(\.isKeyWindow).allSatisfy { ($0.bounds.width > $0.bounds.height) == orientation.isLandscape } })
    }

    private func inspect(_ controller: UIViewController, label: String, expected: UIEdgeInsets) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        guard let input = composer(in: controller.view), let window = controller.view.window else {
            Issue.record("Missing visible composer at \(label)")
            return
        }
        let frame = input.convert(input.bounds, to: window)
        print("SAFE-AREA \(label) window=\(window.safeAreaInsets) host=\(controller.view.safeAreaInsets) composer=\(frame) bounds=\(window.bounds)")
        #expect(controller.view.safeAreaInsets == expected)
        #expect(frame.minY > expected.top)
        #expect(frame.maxY <= window.bounds.maxY - expected.bottom + ComposerMetrics.restingSafeAreaOverlap)
    }

    private func presented(in root: UIViewController) -> UIViewController? {
        root.presentedViewController ?? root.children.lazy.compactMap { presented(in: $0) }.first
    }

    private func composer(in root: UIView) -> UITextView? {
        if let input = root as? UITextView, input.accessibilityIdentifier == "codex-composer-input" { return input }
        return root.subviews.lazy.compactMap { composer(in: $0) }.first
    }
}
