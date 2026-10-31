import Observation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct HTMLVisualStreamingBodyTests {
    @Test(arguments: [false, true])
    func mixedRepliesKeepNarrowDependenciesAcrossHostedRoots(captureFirst: Bool) async throws {
        if captureFirst {
            try await settledVisualKeepsInheritedConversationCapturePause()
            try await mixedReplyKeepsSettledBlockBodiesAndUpdatesItsMenuMessage()
        } else {
            try await mixedReplyKeepsSettledBlockBodiesAndUpdatesItsMenuMessage()
            try await settledVisualKeepsInheritedConversationCapturePause()
        }
    }

    private func settledVisualKeepsInheritedConversationCapturePause() async throws {
        let fixture = MixedReplyFixture()
        fixture.message.isStreaming = false
        fixture.captureAllowed = false
        await fixture.rendered.prepare([fixture.message])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: MixedReplyView(fixture: fixture).environment(AppThemeStore()))
        window.show(controller)
        defer { window.close(); fixture.rendered.retire() }
        try await wait(controller) { fixture.counter.capturePermissions[1] == false }
        fixture.captureAllowed = true
        try await wait(controller) { fixture.counter.capturePermissions[1] == true }
        fixture.message.isStreaming = true
        await fixture.rendered.prepare([fixture.message])
        try await wait(controller) { fixture.counter.capturePermissions[1] == false }
    }

    private func mixedReplyKeepsSettledBlockBodiesAndUpdatesItsMenuMessage() async throws {
        let fixture = MixedReplyFixture()
        await fixture.rendered.prepare([fixture.message])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: MixedReplyView(fixture: fixture).environment(AppThemeStore()))
        window.show(controller)
        defer { window.close(); fixture.rendered.retire() }
        try await wait(controller) { fixture.counter.counts[2, default: 0] > 0 }
        let settledBodies = fixture.counter.counts[0, default: 0]
        let visualBodies = fixture.counter.counts[1, default: 0]
        let owner = try #require(fixture.counter.menuOwner)
        for suffix in [" one", " two", " three"] {
            let tailBodies = fixture.counter.counts[2, default: 0]
            let previous = try #require(fixture.rendered[fixture.message.id])
            fixture.message.text += suffix
            await fixture.rendered.prepare([fixture.message])
            let current = try #require(fixture.rendered[fixture.message.id])
            try #require(current.blocks[0] == previous.blocks[0])
            try #require(current.blocks[1] == previous.blocks[1])
            try await wait(controller) { fixture.counter.counts[2, default: 0] > tailBodies }
            #expect(fixture.counter.counts[0, default: 0] == settledBodies)
            #expect(fixture.counter.counts[1, default: 0] == visualBodies)
            #expect(fixture.counter.menuOwner === owner)
            #expect(owner.message.text == fixture.message.text)
        }
        fixture.message.text = fixture.message.text.replacingOccurrences(of: "Settled heading", with: "Updated heading")
        await fixture.rendered.prepare([fixture.message])
        try await wait(controller) { fixture.counter.counts[0, default: 0] > settledBodies }
        #expect(fixture.counter.counts[1, default: 0] == visualBodies)
        #expect(owner.message.text == fixture.message.text)
    }

    private func wait(_ controller: UIViewController, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

@MainActor
@Observable
private final class MixedReplyFixture {
    var captureAllowed = true
    var message = ChatMessage(role: .codex,
        text: "## Settled heading\n\n![Visual](rc-visual:" + String(repeating: "a", count: 64) + ")\n\nLive tail",
        isStreaming: true)
    let rendered = RenderedMessageStore()
    let visibility = TranscriptVisibility()
    let counter = MarkdownBlockBodyCounter()
}

private struct MixedReplyView: View {
    let fixture: MixedReplyFixture

    var body: some View {
        ChatBubble(message: fixture.message, renderedMessages: fixture.rendered, onFork: nil, queuedActions: nil)
            .environment(\.markdownBlockBodyCounter, fixture.counter)
            .environment(\.htmlVisualCaptureAllowed, fixture.captureAllowed)
            .frame(width: 320)
    }
}
