import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct TranscriptScrollRenderingTests {
    @Test func anEvictedOlderRenderDoesNotResolveItsBookmarkAgainstPlaceholderGeometry() async throws {
        let fixture = TranscriptScrollFixture()
        let messages = (0..<12).flatMap { index in [
            ChatMessage(role: .user, text: "Question \(index)"),
            ChatMessage(role: .codex, text: String(repeating: "Older reading answer \(index).\n\n", count: 90))
        ] }
        let message = messages[5]
        let rowID = ChatStreamItem.message(message).id
        await fixture.store.prepare(messages)
        fixture.store.trim(keeping: Set(messages.suffix(8).map(\.id)))
        #expect(fixture.store[message.id] == nil)
        await fixture.store.prepare(messages.filter { $0.id != message.id })
        let saved = try #require(TranscriptReadingAnchor(rowID: rowID,
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        fixture.readingPosition.record(isFollowingLatest: false, anchor: saved,
            mountedStartRowID: ChatStreamItem.message(messages[0]).id)
        fixture.items = messages.map(ChatStreamItem.message)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(AppThemeStore()).environment(\.scenePhase, .active))
        hosted.show(controller)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: controller.view)
        try await settle(scroll)
        fixture.readingPosition.capture(scope: fixture.readingScope)
        #expect(fixture.store[message.id] == nil)
        #expect(fixture.readingPosition.anchor == saved)
        #expect(!fixture.readingPosition.isFollowingLatest)
        await fixture.store.prepare([message])
        try await settle(scroll)
        fixture.readingPosition.capture(scope: fixture.readingScope)
        let restored = try #require(fixture.readingPosition.anchor)
        #expect(restored.rowID == rowID)
        #expect(restored.rowHeight > saved.rowHeight)
        #expect(abs(restored.rowFraction - saved.rowFraction) * restored.rowHeight < 2)
        #expect(!fixture.readingPosition.isFollowingLatest)
    }

    @Test func aRetainedOwnerArrivingAfterAnEmptyMountRestoresReadingBeforeContentAndStaysThere() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(AppThemeStore()).environment(\.scenePhase, .active))
        hosted.show(controller)
        defer { hosted.close() }
        try await Task.sleep(for: .milliseconds(100))
        let messages = (0..<30).flatMap { index in [
            ChatMessage(role: .user, text: "Question \(index)"),
            ChatMessage(role: .codex, text: String(repeating: "Reading answer \(index).\n\n", count: 12))
        ] }
        let rowID = ChatStreamItem.message(messages[20]).id
        let saved = TranscriptReadingPosition()
        let anchor = try #require(TranscriptReadingAnchor(rowID: rowID,
            frame: CGRect(x: 0, y: 0, width: 600, height: 200),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 800)))
        saved.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: ChatStreamItem.message(messages[0]).id)
        fixture.readingPosition = saved
        await fixture.show(messages)
        let scroll = try await waitForScroll(in: controller.view)
        try await settle(scroll)
        #expect(scroll.contentOffset.y + scroll.bounds.height < scroll.contentSize.height - 100)
        saved.capture(scope: fixture.readingScope)
        #expect(!saved.isFollowingLatest)
        #expect(saved.anchor?.rowID == rowID)
        let offset = scroll.contentOffset.y
        await fixture.show(messages + [ChatMessage(role: .codex,
            text: String(repeating: "New content below the retained reader.\n\n", count: 30))])
        try await settle(scroll)
        #expect(abs(scroll.contentOffset.y - offset) < 2)
        saved.capture(scope: fixture.readingScope)
        #expect(!saved.isFollowingLatest)
        #expect(saved.anchor?.rowID == rowID)
    }

    @Test func compactionCompletionAndContinuationKeepTheTranscriptReaderInPlace() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(AppThemeStore()).environment(\.colorScheme, .light)
            .environment(\.scenePhase, .active)
            .environment(\.appEnergyPolicy, AppEnergyPolicy(isLowPowerModeEnabled: false, thermalState: .nominal)))
        hosted.show(controller)
        defer { hosted.close() }

        let user = ChatMessage(role: .user, text: "Continue working on the design")
        let before = ChatMessage(role: .codex, text: "I’ve checked how the conversation history is built. The next step is to update the transcript layout.")
        await fixture.show([user, before])
        var marker = CompactionMarker(id: "compaction-rendering", compaction:
            ConversationCompaction(turnID: "turn", itemID: "compact", phase: .running))
        fixture.items.append(.compaction(marker))
        let scroll = try await waitForScroll(in: controller.view)
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(user).id, token: 1, anchor: .top, motion: .animated)
        try await settle(scroll)
        let offset = scroll.contentOffset.y
        let height = scroll.contentSize.height
        recordScreenshot(in: controller.view, named: "context-compacting.png")

        marker.compaction.phase = .completed
        fixture.items[2] = .compaction(marker)
        try await settle(scroll)
        #expect(abs(scroll.contentOffset.y - offset) < 2, "Completing compaction preserves the reading position")
        #expect(abs(scroll.contentSize.height - height) < 2, "The settled divider keeps the running row’s height")
        recordScreenshot(in: controller.view, named: "context-compacted.png")

        let after = ChatMessage(role: .codex, text: String(repeating: "The conversation continues below the context divider.\n\n", count: 30))
        await fixture.store.prepare([after])
        fixture.items.append(.message(after))
        try await settle(scroll)
        #expect(scroll.contentSize.height > height + 100, "Continuation renders below the divider")
        #expect(abs(scroll.contentOffset.y - offset) < 2, "Continuation keeps the reader above the divider")
        recordScreenshot(in: controller.view, named: "context-compacted-continuation.png")

        let continuationHeight = scroll.contentSize.height
        marker.compaction.requestID = UUID()
        for phase in [ConversationCompaction.Phase.requesting, .running, .completed, .unconfirmed] {
            marker.compaction.phase = phase
            fixture.items[2] = .compaction(marker)
            try await settle(scroll)
            #expect(scroll.contentSize.height >= continuationHeight + ControlMetrics.minimumTarget,
                "Every blocking manual phase must render its Refresh control")
        }
        marker.compaction.phase = .completed
        fixture.items[2] = .compaction(marker)
        try await settle(scroll)
        recordScreenshot(in: controller.view, named: "context-compacted-manual-recovery.png")
        marker.compaction.turnFinished = true
        fixture.items[2] = .compaction(marker)
        try await settle(scroll)
        #expect(abs(scroll.contentSize.height - continuationHeight) < 2,
            "Confirmed completion leaves only the permanent divider")
    }

    private func recordScreenshot(in view: UIView, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        if let data = image.pngData() { Attachment.record(data, named: name) }
    }

    @Test func aTopAnchoredSendRemainsStationaryThroughGrowthAndCompletion() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let theme = AppThemeStore()
        let previousTheme = theme.selectedThemeID
        theme.selectedThemeID = .caribbeanSunset
        defer { theme.selectedThemeID = previousTheme }
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(theme).environment(\.colorScheme, .light))
        hosted.show(controller)
        defer { hosted.close() }

        let oldUser = ChatMessage(role: .user, text: "Earlier question")
        let oldReply = ChatMessage(role: .codex, text: String(repeating: "Earlier content fills the viewport.\n\n", count: 40))
        await fixture.show([oldUser, oldReply])
        let scroll = try await waitForScroll(in: controller.view)
        try await settle(scroll)
        let initialOffset = scroll.contentOffset.y

        let user = ChatMessage(role: .user, text: "Please stream the next answer")
        var reply = ChatMessage(role: .codex, text: "First words", isStreaming: true)
        fixture.isActive = true
        await fixture.show([oldUser, oldReply, user, reply])
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(user).id, token: 1, anchor: .top, motion: .animated)
        try await settle(scroll)
        let anchoredOffset = scroll.contentOffset.y
        #expect(anchoredOffset > initialOffset + 100)
        // Measure the actual displayed bubble. A separate ImageRenderer can
        // use different font/layout traits than this live hosting window.
        let top = try userBubbleTop(in: controller.view)
        #expect(abs(top - bubbleRestingTop(in: scroll)) < 3,
                "The new user bubble must reach the visible top, not merely move upward")
        let initialHeight = scroll.contentSize.height

        for index in 1...6 {
            reply.text += "\n\n## Section \(index)\n" + String(repeating: "New words grow below the stationary reader. ", count: 14)
            await fixture.show([oldUser, oldReply, user, reply])
            try await settle(scroll)
            #expect(abs(scroll.contentOffset.y - anchoredOffset) < 2,
                    "Streaming must not move the top-anchored reading position")
        }
        #expect(scroll.contentSize.height > initialHeight + scroll.bounds.height)
        reply.isStreaming = false
        await fixture.show([oldUser, oldReply, user, reply])
        fixture.isActive = false
        try await settle(scroll)
        #expect(abs(scroll.contentOffset.y - anchoredOffset) < 2,
                "Finishing the reply must not jump to its bottom")
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(image.pngData()), named: "streaming-top-anchor-complete.png")

        fixture.composerHeight = 260
        try await settle(scroll)
        #expect(abs(try userBubbleTop(in: controller.view) - bubbleRestingTop(in: scroll)) < 3)
        fixture.composerHeight = 100
        try await settle(scroll)
        #expect(abs(scroll.contentOffset.y - anchoredOffset) < 2)

        let nextUser = ChatMessage(role: .user, text: "Please write another short reply")
        var nextReply = ChatMessage(role: .codex, text: "Short reply", isStreaming: true)
        fixture.isActive = true
        await fixture.show([oldUser, oldReply, user, reply, nextUser, nextReply])
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(nextUser).id, token: 2, anchor: .top, motion: .animated)
        try await settle(scroll)
        let nextTop = try userBubbleTop(in: controller.view)
        #expect(abs(nextTop - bubbleRestingTop(in: scroll)) < 3)
        let nextImage = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(nextImage.pngData()), named: "streaming-next-send.png")
        let nextOffset = scroll.contentOffset.y
        nextReply.isStreaming = false
        fixture.isActive = false
        await fixture.show([oldUser, oldReply, user, reply, nextUser, nextReply])
        try await settle(scroll)
        #expect(abs(scroll.contentOffset.y - nextOffset) < 2)

        fixture.showsBottomBar = true
        try await settle(scroll)
        #expect(abs(try userBubbleTop(in: controller.view) - nextTop) < 3,
                "A bar appearing above the composer must not move the top-anchored reader")
    }

    @Test func aLongTranscriptMountsWholeTurnBatchesAboveTheReaderAndKeepsItInPlace() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let theme = AppThemeStore()
        let previousTheme = theme.selectedThemeID
        theme.selectedThemeID = .caribbeanSunset
        defer { theme.selectedThemeID = previousTheme }
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(theme).environment(\.colorScheme, .light))
        hosted.show(controller)
        defer { hosted.close() }

        let messages = (0..<60).flatMap { index in [
            ChatMessage(role: .user, text: "Question \(index): please explain the next part of this design"),
            ChatMessage(role: .codex, text: String(repeating: "Answer \(index) explains one more detail.\n\n", count: 6)),
        ] }
        await fixture.show(messages)
        let scroll = try await waitForScroll(in: controller.view)
        try await Task.sleep(for: .milliseconds(600))
        try await settle(scroll)
        let following = scroll.contentSize.height
        let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
        #expect(visibleBottom >= scroll.contentSize.height - 2, "Mounting above a follower must keep it at the latest row")

        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(messages[80]).id, token: 1, anchor: .top, motion: .instant)
        try await Task.sleep(for: .milliseconds(100))
        try await settle(scroll)
        let runway = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let turnHeight = (scroll.contentSize.height - following) / 25
        #expect(turnHeight > 40, "Resting five turns below the mounted top mounts an earlier batch")
        #expect(following > turnHeight * 24.5 && following < turnHeight * 25 + scroll.bounds.height + 40,
                "A follower mounts the latest 25 turns, not the whole transcript")
        #expect(abs(runway - turnHeight * 30) < turnHeight / 2, "The reader gets exactly one more batch of 25 turns above it")
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(image.pngData()), named: "bounded-window-reader.png")
        #expect(abs(try userBubbleTop(in: controller.view) - bubbleRestingTop(in: scroll)) < 3,
                "Mounting above must restore the reader's row to the top")
    }

    @Test(arguments: [false, true])
    func returningTowardRecentMessagesTrimsThePrefixWithoutLosingTheReaderOrOlderContent(includesUserPrompts: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let theme = AppThemeStore()
        let previousTheme = theme.selectedThemeID
        theme.selectedThemeID = .caribbeanSunset
        defer { theme.selectedThemeID = previousTheme }
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(theme).environment(\.colorScheme, .light))
        hosted.show(controller)
        defer { hosted.close() }

        let messages = (0..<80).flatMap { index in [
            ChatMessage(role: includesUserPrompts ? .user : .codex, text: "Question \(index): explain this part"),
            ChatMessage(role: .codex, text: String(repeating: "Answer \(index) explains one more detail.\n\n", count: 6)),
        ] }
        await fixture.show(messages)
        let scroll = try await waitForScroll(in: controller.view)
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(messages[0]).id, token: 1, anchor: .top, motion: .instant)
        try await Task.sleep(for: .milliseconds(600))
        try await settle(scroll)
        let fullHeight = scroll.contentSize.height

        let recentID = ChatStreamItem.message(messages[144]).id
        fixture.request = TranscriptRowRequest(rowID: recentID, token: 2, anchor: .top, motion: .animated)
        try await Task.sleep(for: .milliseconds(800))
        try await settle(scroll)
        fixture.readingPosition.capture(scope: fixture.readingScope)
        #expect(scroll.contentSize.height < fullHeight * 0.7)
        let anchor = try #require(fixture.readingPosition.anchor)
        #expect(anchor.rowID == recentID)
        #expect(anchor.rowOffset < 2 && anchor.viewportFraction < 0.01)
        if includesUserPrompts {
            #expect(abs(try userBubbleTop(in: controller.view) - bubbleRestingTop(in: scroll)) < 3)
        }

        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(messages[0]).id, token: 3, anchor: .top, motion: .animated)
        try await Task.sleep(for: .milliseconds(800))
        try await settle(scroll)
        fixture.readingPosition.capture(scope: fixture.readingScope)
        #expect(scroll.contentSize.height > fullHeight * 0.9)
        #expect(fixture.readingPosition.anchor?.rowID == ChatStreamItem.message(messages[0]).id)
    }

    @Test func earlierRowsWaitForTheirRenderBeforeMountingAboveTheReader() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let gate = MountRenderGate()
        let fixture = TranscriptScrollFixture(store: RenderedMessageStore { batch in
            await gate.pass()
            var highlighting = SyntaxHighlightCache()
            return batch.map { ($0.id, RenderedMessage.render(text: $0.text, inline: $0.inline, isStreaming: $0.isStreaming,
                previous: $0.previous, highlighting: &highlighting)) }
        })
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(controller)
        defer { hosted.close() }

        let messages = (0..<60).flatMap { index in [
            ChatMessage(role: .user, text: "Question \(index)"),
            ChatMessage(role: .codex, text: String(repeating: "Answer \(index) explains one more detail.\n\n", count: 6)),
        ] }
        await fixture.store.prepare(Array(messages.suffix(2)))
        await gate.close()
        fixture.items = messages.map(ChatStreamItem.message)
        let scroll = try await waitForScroll(in: controller.view)
        try await Task.sleep(for: .milliseconds(600))
        try await settle(scroll)
        #expect(scroll.contentSize.height < scroll.bounds.height * 1.3, "An unrendered batch must not mount")

        await gate.open()
        try await Task.sleep(for: .milliseconds(600))
        try await settle(scroll)
        #expect(scroll.contentSize.height > scroll.bounds.height * 1.5, "The rendered batch mounts once ready")
        let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
        #expect(visibleBottom >= scroll.contentSize.height - 2)
    }

    @Test func aShortReplyUnderATallComposerShowsNoJumpControl() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(AppThemeStore()).environment(\.colorScheme, .light))
        hosted.show(controller)
        defer { hosted.close() }

        let user = ChatMessage(role: .user, text: "test")
        let reply = ChatMessage(role: .codex, text: "Short reply")
        fixture.composerHeight = 400
        await fixture.show([user, reply])
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(user).id, token: 1, anchor: .top, motion: .instant)
        let scroll = try await waitForScroll(in: controller.view)
        try await settle(scroll)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try darkPixelsInJumpControlCorner(in: controller.view, scroll: scroll) == 0,
                "Only the latest turn's reserved space lies below the reader")
    }

    @Test func readingFarAboveTheLatestAnswerShowsTheJumpControl() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = TranscriptScrollFixture()
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture)
            .environment(AppThemeStore()).environment(\.colorScheme, .light))
        hosted.show(controller)
        defer { hosted.close() }

        let answers = (0..<40).map { ChatMessage(role: .codex, text: String(repeating: "Answer \($0).\n", count: 8)) }
        await fixture.show(answers)
        let scroll = try await waitForScroll(in: controller.view)
        try await settle(scroll)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try darkPixelsInJumpControlCorner(in: controller.view, scroll: scroll) == 0, "A follower at the latest answer needs no jump")

        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(answers[2]).id, token: 1, anchor: .top, motion: .instant)
        try await settle(scroll)
        try await Task.sleep(for: .milliseconds(400))
        try #require(scroll.contentOffset.y + scroll.bounds.height < scroll.contentSize.height - scroll.bounds.height / 2)
        recordScreenshot(in: controller.view, named: "jump-control-above-latest.png")
        #expect(try darkPixelsInJumpControlCorner(in: controller.view, scroll: scroll) > 40)
    }

    private func darkPixelsInJumpControlCorner(in view: UIView, scroll: UIScrollView) throws -> Int {
        let bottom = scroll.convert(scroll.bounds, to: view).maxY - scroll.adjustedContentInset.bottom
        let region = CGRect(x: view.bounds.maxX - 100, y: bottom - 90, width: 100, height: 90)
        let image = UIGraphicsImageRenderer(bounds: region).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width,
                height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo:
                    CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).count { offset in
            pixels[offset] < 100 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 && pixels[offset + 3] > 200
        }
    }

    private func bubbleRestingTop(in scroll: UIScrollView) -> CGFloat {
        scroll.adjustedContentInset.top + ChatBubble.messageVerticalInset
    }

    private func userBubbleTop(in view: UIView) throws -> CGFloat {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width,
                height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo:
                    CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        // Caribbean Sunset's wide, tinted bubble is distinct from text and the
        // small jump control. Requiring a wide run also excludes corner pixels.
        for y in 0..<cgImage.height {
            let count = (0..<cgImage.width).count { x in
                let offset = (y * cgImage.width + x) * 4
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                return red > 170 && red - green > 12 && green - blue > 2
            }
            if count > cgImage.width / 3 { return CGFloat(y) / image.scale }
        }
        throw FixtureError.bubbleNotVisible
    }

    private func waitForScroll(in view: UIView) async throws -> UIScrollView {
        for _ in 0..<100 {
            if let scroll = scrollView(in: view), scroll.bounds.height > 100, scroll.contentSize.height > 0 { return scroll }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.scrollNotMounted
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }

    private func settle(_ scroll: UIScrollView) async throws {
        // Allow SwiftUI's layout/geometry observations to traverse the run loop.
        // Consecutive identical samples also wait out the finite scroll/growth animations.
        var previous = (CGFloat.nan, CGFloat.nan)
        var stable = 0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            scroll.superview?.layoutIfNeeded()
            let current = (scroll.contentOffset.y, scroll.contentSize.height)
            stable = abs(current.0 - previous.0) < 0.1 && abs(current.1 - previous.1) < 0.1 ? stable + 1 : 0
            if stable >= 10 { return }
            previous = current
        }
        throw FixtureError.didNotSettle
    }

    private enum FixtureError: Error { case scrollNotMounted, didNotSettle, bubbleNotVisible }
}

@MainActor
@Observable
private final class TranscriptScrollFixture {
    var readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let store: RenderedMessageStore
    var items: [ChatStreamItem] = []
    var request: TranscriptRowRequest?
    var isActive = false
    var composerHeight: CGFloat = 100
    var showsBottomBar = false

    init(store: RenderedMessageStore = RenderedMessageStore()) { self.store = store }

    func show(_ messages: [ChatMessage]) async {
        await store.prepare(messages)
        items = messages.map(ChatStreamItem.message)
    }
}

private struct TranscriptScrollFixtureView: View {
    let fixture: TranscriptScrollFixture

    var body: some View {
        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.store, forkableMessageIDs: [],
            scrollToRow: fixture.request,
            onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
            onRefreshCompaction: {},
            onBackgroundTap: {}, historyEdgeStatus: [:], canPrefetchOlderHistory: true, canLoadHistory: true, onLoadHistory: { _ in nil }, onShowLatest: {},
            onFirstContent: {},
            bottomBar: fixture.showsBottomBar ? Color.clear.frame(height: 44) : nil)
            .safeAreaInset(edge: .top) { Text("Transcript rendering test").padding() }
            .safeAreaInset(edge: .bottom) { Text("Composer").frame(height: fixture.composerHeight) }
    }
}


extension TranscriptScrollRenderingTests {
    @Test(arguments: [0.0, 0.4])
    func anExpandedReadingTargetStaysInPlaceWhenAnOlderPageRevealsAMessage(anchorY: Double) async throws {
        let fixture = HistoryPagingRenderFixture()
        fixture.seed()
        await fixture.publish()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: HistoryPagingRenderView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(host)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: host.view)
        fixture.request = TranscriptRowRequest(rowID: "activity-gw-thread-turn-cmd-18", token: 1, anchor: UnitPoint(x: 0, y: anchorY), motion: .instant)
        try await Task.sleep(for: .milliseconds(1_200))
        try await settle(scroll)
        let before = (scroll.contentSize.height, scroll.contentOffset.y)
        let beforeImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(beforeImage.pngData()), named: "history-before-page.png")
        let action = try #require(fixture.buttonActions.min(by: { $0.value.frame.minY < $1.value.frame.minY })?.value.action)
        action()
        for _ in 0..<100 where fixture.loadCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.loadCount == 1)
        try await settle(scroll)
        let heightAdded = scroll.contentSize.height - before.0
        let offsetAdded = scroll.contentOffset.y - before.1
        #expect(heightAdded > 40, "The new message and section must actually change layout")
        #expect(abs(heightAdded - offsetAdded) < 3,
            "The same canonical activity must retain its screen position when content is added above it")
        let snapshot = ConversationProjection.project(fixture.state)
        #expect(snapshot.timelines.contains { $0.isExpanded && $0.events.contains { $0.id == "gw-thread-turn-cmd-18" } })
        #expect(fixture.state.window?.olderEdge == nil)
        #expect(fixture.historyEdgeStatus.isEmpty)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(image.pngData()), named: "history-reading-position.png")
    }
}

@MainActor @Observable
private final class HistoryPagingRenderFixture {
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    var state = ConversationState(conversationID: UUID(), threadID: "thread")
    let store = RenderedMessageStore()
    var items: [ChatStreamItem] = []
    var request: TranscriptRowRequest?
    var historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status] = [.older: .failed]
    var loadCount = 0
    @ObservationIgnored var buttonActions: [UUID: PagingTestButtonAction] = [:]

    func load(_ kind: HistoryEdge.Kind) -> Task<Void, Never>? {
        historyEdgeStatus[kind] = .loading
        return Task {
            defer { historyEdgeStatus[kind] = nil; loadCount += 1 }
            prepend()
            await publish()
        }
    }

    func seed() {
        let turn = CodexAppServerV2.Turn(id: "turn", items: [],
            startedAt: 1, completedAt: nil, status: .inProgress, error: nil)
        state.merge(.fixture(wire: (20..<40).reversed().map(command), turns: [turn], older: "before-20"))
        state.merge(.fixture(wire: (10..<20).reversed().map(command), older: "before-10",
            placement: .older("before-20"), base: state.window))
        state.activity(turnID: "turn", active: true)
        if let timeline = ConversationProjection.project(state).timelines.last { state.toggleTimeline(timeline.id) }
    }

    func prepend() {
        let user = CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn",
            item: .userMessage(id: "user", content: [.text(text: "Load and inspect the candidates", textElements: [])]), isComplete: true)
        let progress = CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn",
            item: .agentMessage(id: "progress", text: "The downloads are complete. Inspecting the imported data now."),
            startedAtOrdinal: 9, startedAtMs: 9000, completedAtMs: 9500, isComplete: true)
        let entries = [user] + (0..<9).map(command) + [progress]
        state.merge(.fixture(wire: entries.reversed(), placement: .older("before-10"), base: state.window))
    }

    func publish() async {
        let projected = ConversationProjection.project(state)
        await store.prepare(projected.messages)
        items = projected.items
    }

    private func command(_ index: Int) -> CodexAppServerV2.ThreadItemsListResponse.Entry {
        .init(turnId: "turn", item: .commandExecution(id: "cmd-\(index)", command: "Synthetic command \(index)",
            cwd: "/tmp/fixture", status: .completed, commandActions: [], aggregatedOutput: "Synthetic output \(index)",
            exitCode: 0, durationMs: 100), startedAtOrdinal: Int64(index), startedAtMs: Int64(index * 1000),
            completedAtMs: Int64(index * 1000 + 100), isComplete: true)
    }
}

private struct HistoryPagingRenderView: View {
    let fixture: HistoryPagingRenderFixture
    var body: some View {
        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.store, forkableMessageIDs: [],
            scrollToRow: fixture.request, onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
            onBackgroundTap: {}, historyEdgeStatus: fixture.historyEdgeStatus, canPrefetchOlderHistory: true, canLoadHistory: true, onLoadHistory: fixture.load, onShowLatest: {},
            onFirstContent: {}, bottomBar: EmptyView?.none)
            .buttonStyle(PagingTestButtonStyle { id, value in fixture.buttonActions[id] = value })
            .safeAreaInset(edge: .bottom) { Text("Fixture composer").frame(height: 100) }
    }
}


extension TranscriptScrollRenderingTests {
    @Test func aVisibleNewerEdgePagesForwardWithoutResettingToTheLatest() async throws {
        let fixture = NewerEdgeRenderFixture()
        await fixture.publish()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: NewerEdgeRenderView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(host)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: host.view)
        for _ in 0..<100 where !fixture.loads.contains(.newer) { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(scroll)
        #expect(fixture.loads.contains(.newer))
        #expect(fixture.latestResets == 0)
    }
}

extension TranscriptScrollRenderingTests {
    @Test func aHistoryReadTheModelCannotStartWaitsForReadinessInsteadOfRetrying() async throws {
        let fixture = UnreadyHistoryRenderFixture()
        await fixture.publish(newerCursor: "after-5")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: UnreadyHistoryRenderView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(host)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: host.view)
        try await Task.sleep(for: .milliseconds(300))
        try await settle(scroll)
        #expect(fixture.attempts > 0)
        #expect(fixture.attempts < 10, "A refused read must not be retried on every update")
        #expect(fixture.started == 0)
        fixture.canLoadHistory = true
        for _ in 0..<100 where fixture.started == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(scroll)
        #expect(fixture.started == 1)
    }
}

@MainActor @Observable
private final class UnreadyHistoryRenderFixture {
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let store = RenderedMessageStore()
    var items: [ChatStreamItem] = []
    var canLoadHistory = false
    var attempts = 0
    var started = 0

    func load(_ kind: HistoryEdge.Kind) -> Task<Void, Never>? {
        attempts += 1
        guard canLoadHistory else { return nil }
        started += 1
        return Task { await publish(newerCursor: nil) }
    }

    func publish(newerCursor: String?) async {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let entries = (0..<6).reversed().map { index in
            CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn-\(index)",
                item: .agentMessage(id: "reply-\(index)", text: "Loaded reply \(index)"), isComplete: true)
        }
        state.merge(.fixture(wire: entries, newer: newerCursor))
        let projected = ConversationProjection.project(state)
        await store.prepare(projected.messages)
        items = projected.items
    }
}

private struct UnreadyHistoryRenderView: View {
    let fixture: UnreadyHistoryRenderFixture
    var body: some View {
        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.store, forkableMessageIDs: [],
            scrollToRow: nil, onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
            onBackgroundTap: {}, historyEdgeStatus: [:], canPrefetchOlderHistory: true, canLoadHistory: fixture.canLoadHistory,
            onLoadHistory: fixture.load, onShowLatest: {},
            onFirstContent: {}, bottomBar: EmptyView?.none)
            .safeAreaInset(edge: .bottom) { Text("Fixture composer").frame(height: 100) }
    }
}

@MainActor @Observable
private final class NewerEdgeRenderFixture {
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let store = RenderedMessageStore()
    var items: [ChatStreamItem] = []
    var loads: [HistoryEdge.Kind] = []
    var latestResets = 0

    func publish() async {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let entries = (0..<6).reversed().map { index in
            CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn-\(index)",
                item: .agentMessage(id: "reply-\(index)", text: "Loaded reply \(index)"), isComplete: true)
        }
        state.merge(.fixture(wire: entries, newer: "after-5"))
        let projected = ConversationProjection.project(state)
        await store.prepare(projected.messages)
        items = projected.items
    }
}

private struct NewerEdgeRenderView: View {
    let fixture: NewerEdgeRenderFixture
    var body: some View {
        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.store, forkableMessageIDs: [],
            scrollToRow: nil, onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
            onBackgroundTap: {}, historyEdgeStatus: [:], canPrefetchOlderHistory: true, canLoadHistory: true,
            onLoadHistory: { fixture.loads.append($0); return nil },
            onShowLatest: { fixture.latestResets += 1 },
            onFirstContent: {}, bottomBar: EmptyView?.none)
            .safeAreaInset(edge: .bottom) { Text("Fixture composer").frame(height: 100) }
    }
}

private struct PagingTestButtonAction {
    let frame: CGRect
    let action: @MainActor () -> Void
}

/// The fixture records public PrimitiveButtonStyle configuration actions. Unlike
/// an external UI runner, an in-process test cannot query offscreen SwiftUI AX nodes.
private struct PagingTestButtonStyle: PrimitiveButtonStyle {
    let record: @MainActor (UUID, PagingTestButtonAction?) -> Void
    func makeBody(configuration: Configuration) -> some View {
        CapturedButton(configuration: configuration, record: record)
    }
    private struct CapturedButton: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let record: @MainActor (UUID, PagingTestButtonAction?) -> Void
        @State private var id = UUID()
        var body: some View {
            configuration.label
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _, frame in
                    record(id, .init(frame: frame, action: { configuration.trigger() }))
                }
                .onDisappear { record(id, nil) }
        }
    }
}

private actor MountRenderGate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }

    func close() { isOpen = false }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

extension TranscriptScrollRenderingTests {
    @Test(arguments: zip([24, 18], [0.5, 0.9]))
    func aReaderBetweenTwoLongRepliesStaysInPlaceWhenAnEarlierBatchMounts(paragraphs: Int, boundary: Double) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let gate = MountRenderGate()
        let fixture = TranscriptScrollFixture(store: RenderedMessageStore { batch in
            await gate.pass()
            var highlighting = SyntaxHighlightCache()
            return batch.map { ($0.id, RenderedMessage.render(text: $0.text, inline: $0.inline, isStreaming: $0.isStreaming,
                previous: $0.previous, highlighting: &highlighting)) }
        })
        let controller = UIHostingController(rootView: TranscriptScrollFixtureView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(controller)
        defer { hosted.close() }

        let replies = (0..<24).map { longReply($0, paragraphs: paragraphs) }
        let items = replies.map(ChatStreamItem.message)
        let opening = TranscriptRow.openingStart(of: TranscriptRow.make(items))
        await fixture.store.prepare(Array(replies[opening...]))
        await gate.close()
        fixture.items = items
        let scroll = try await waitForScroll(in: controller.view)
        try await settle(scroll)
        fixture.request = TranscriptRowRequest(rowID: items[opening].id, token: 1, anchor: .bottom, motion: .instant)
        try await Task.sleep(for: .milliseconds(700))
        try await settle(scroll)
        let viewport = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        let straddling = scroll.contentOffset.y + viewport * (1 - boundary)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: straddling), animated: false)
        try await settle(scroll)
        #expect(abs(scroll.contentOffset.y - straddling) < 1)
        let before = (scroll.contentSize.height, scroll.contentOffset.y)

        await gate.open()
        try await Task.sleep(for: .milliseconds(600))
        try await settle(scroll)
        let heightAdded = scroll.contentSize.height - before.0
        let offsetAdded = scroll.contentOffset.y - before.1
        #expect(heightAdded > viewport, "Earlier replies must mount above the resting reader")
        #expect(abs(heightAdded - offsetAdded) < 3,
            "A reader resting between two partly visible replies must not move when rows mount above")
    }

    @Test(arguments: [false, true])
    func anOlderPageWaitsAboveAFullyMountedWindowAndMountsWithoutMovingTheReader(reachesThreadStart: Bool) async throws {
        let fixture = OlderPageRenderFixture(pageReachesThreadStart: reachesThreadStart)
        await fixture.seed()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: OlderPageRenderView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(host)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: host.view)
        try await Task.sleep(for: .milliseconds(600))
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(fixture.window[0]).id, token: 1, anchor: .top, motion: .instant)
        try await Task.sleep(for: .milliseconds(1_200))
        try await settle(scroll)
        let viewport = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        let before = (scroll.contentSize.height, scroll.contentOffset.y)

        await fixture.gate.close()
        let retry = try #require(fixture.buttonActions.min(by: { $0.value.frame.minY < $1.value.frame.minY })?.value.action)
        retry()
        for _ in 0..<100 where fixture.loadCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.loadCount == 1)
        try await Task.sleep(for: .milliseconds(300))
        try await settle(scroll)
        #expect(abs(scroll.contentSize.height - before.0) < 1,
            "An older page must wait above the window until its messages render, not mount at once")
        #expect(abs(scroll.contentOffset.y - before.1) < 1)

        await fixture.gate.open()
        try await Task.sleep(for: .milliseconds(600))
        try await settle(scroll)
        let heightAdded = scroll.contentSize.height - before.0
        let offsetAdded = scroll.contentOffset.y - before.1
        #expect(heightAdded > viewport, "The page's replies must mount above the reader once rendered")
        #expect(abs(heightAdded - offsetAdded) < 3, "Mounting the page must not move the reader")
    }

    @Test func olderPagesKeepLoadingAboveARestingReaderUntilTheThreadStart() async throws {
        let fixture = ChainedPagesRenderFixture()
        await fixture.seed()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: ChainedPagesRenderView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(host)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: host.view)
        try await Task.sleep(for: .milliseconds(600))
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(fixture.replies[8]).id, token: 1, anchor: .top, motion: .instant)
        try await Task.sleep(for: .milliseconds(700))
        try await settle(scroll)
        let viewport = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        let before = (scroll.contentSize.height, scroll.contentOffset.y)

        fixture.historyEdgeStatus = [:]
        for _ in 0..<300 where fixture.loadCount < fixture.pages.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.loadCount == fixture.pages.count, "Each settled page must demand the next while the backlog is short")
        try await Task.sleep(for: .milliseconds(1_500))
        try await settle(scroll)
        let heightAdded = scroll.contentSize.height - before.0
        let offsetAdded = scroll.contentOffset.y - before.1
        #expect(heightAdded > viewport * 2, "Every page must mount above the resting reader")
        #expect(abs(heightAdded - offsetAdded) < 3, "Paging and mounting above the reader must not move it")
    }

    @Test func aHistoryWindowWithoutRoomPagesOnlyFromAVisibleEdge() async throws {
        let fixture = ChainedPagesRenderFixture()
        fixture.canPrefetchOlderHistory = false
        await fixture.seed()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: ChainedPagesRenderView(fixture: fixture).environment(AppThemeStore()))
        hosted.show(host)
        defer { hosted.close() }
        let scroll = try await waitForScroll(in: host.view)
        try await Task.sleep(for: .milliseconds(600))
        fixture.request = TranscriptRowRequest(rowID: ChatStreamItem.message(fixture.replies[10]).id, token: 1, anchor: .top, motion: .instant)
        try await Task.sleep(for: .milliseconds(700))
        try await settle(scroll)
        fixture.historyEdgeStatus = [:]
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.loadCount == 0, "Background paging must never make the window evict the latest history")
    }
}

@MainActor @Observable
private final class ChainedPagesRenderFixture {
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let store = RenderedMessageStore()
    let pages = (0..<4).map { page in (0..<6).map { longReply(100 + page * 6 + $0, paragraphs: 2) } }
    var replies = (0..<12).map { longReply($0, paragraphs: 2) }
    var items: [ChatStreamItem] = []
    var request: TranscriptRowRequest?
    var historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status] = [.older: .failed]
    var canPrefetchOlderHistory = true
    var loadCount = 0

    func seed() async {
        await store.prepare(replies)
        publish()
    }

    func load(_ kind: HistoryEdge.Kind) -> Task<Void, Never>? {
        guard loadCount < pages.count else { return nil }
        historyEdgeStatus[kind] = .loading
        let page = pages[pages.count - 1 - loadCount]
        loadCount += 1
        return Task {
            await store.prepare(page)
            replies = page + replies
            publish()
            historyEdgeStatus[kind] = nil
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func publish() {
        let edge: [ChatStreamItem] = loadCount < pages.count ? [.historyEdge(HistoryEdge(kind: .older, cursor: "page-\(loadCount)"))] : []
        items = edge + replies.map(ChatStreamItem.message)
    }
}

private struct ChainedPagesRenderView: View {
    let fixture: ChainedPagesRenderFixture
    var body: some View {
        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.store, forkableMessageIDs: [],
            scrollToRow: fixture.request, onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
            onBackgroundTap: {}, historyEdgeStatus: fixture.historyEdgeStatus, canPrefetchOlderHistory: fixture.canPrefetchOlderHistory, canLoadHistory: true, onLoadHistory: fixture.load, onShowLatest: {},
            onFirstContent: {}, bottomBar: EmptyView?.none)
            .safeAreaInset(edge: .bottom) { Text("Fixture composer").frame(height: 100) }
    }
}

private func longReply(_ index: Int, paragraphs: Int) -> ChatMessage {
    ChatMessage(role: .codex, text: String(repeating: "Reply \(index) keeps explaining the design in more detail.\n\n", count: paragraphs))
}

@MainActor @Observable
private final class OlderPageRenderFixture {
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let gate: MountRenderGate
    let store: RenderedMessageStore
    let window = (4..<7).map { longReply($0, paragraphs: 24) }
    let page = (0..<4).map { longReply($0, paragraphs: 24) }
    var items: [ChatStreamItem] = []
    var request: TranscriptRowRequest?
    let historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status] = [.older: .failed]
    var loadCount = 0
    @ObservationIgnored var buttonActions: [UUID: PagingTestButtonAction] = [:]
    private let pageReachesThreadStart: Bool

    init(pageReachesThreadStart: Bool) {
        self.pageReachesThreadStart = pageReachesThreadStart
        let gate = MountRenderGate()
        self.gate = gate
        store = RenderedMessageStore { batch in
            await gate.pass()
            var highlighting = SyntaxHighlightCache()
            return batch.map { ($0.id, RenderedMessage.render(text: $0.text, inline: $0.inline, isStreaming: $0.isStreaming,
                previous: $0.previous, highlighting: &highlighting)) }
        }
    }

    func seed() async {
        await store.prepare(window)
        items = [.historyEdge(HistoryEdge(kind: .older, cursor: "before-window"))] + window.map(ChatStreamItem.message)
    }

    func load(_ kind: HistoryEdge.Kind) -> Task<Void, Never>? {
        loadCount += 1
        guard loadCount == 1 else { return nil }
        let earlier: [ChatStreamItem] = pageReachesThreadStart ? [] : [.historyEdge(HistoryEdge(kind: .older, cursor: "before-page"))]
        items = earlier + (page + window).map(ChatStreamItem.message)
        return Task {}
    }
}

private struct OlderPageRenderView: View {
    let fixture: OlderPageRenderFixture
    var body: some View {
        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.store, forkableMessageIDs: [],
            scrollToRow: fixture.request, onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
            onBackgroundTap: {}, historyEdgeStatus: fixture.historyEdgeStatus, canPrefetchOlderHistory: true, canLoadHistory: true, onLoadHistory: fixture.load, onShowLatest: {},
            onFirstContent: {}, bottomBar: EmptyView?.none)
            .buttonStyle(PagingTestButtonStyle { id, value in fixture.buttonActions[id] = value })
            .safeAreaInset(edge: .bottom) { Text("Fixture composer").frame(height: 100) }
    }
}
