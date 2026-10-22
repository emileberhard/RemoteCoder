import Foundation
import Observation
import Synchronization
import Testing
@testable import RemoteCoder

@MainActor
struct RenderedMessageStoreTests {
    @Test func readingFramePresenceDoesNotObserveStreamingPayloadRevisions() async {
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        var message = ChatMessage(role: .codex, text: "First render", isStreaming: true)
        await store.prepare([message])
        let changed = Mutex(false)
        withObservationTracking { _ = store.hasPresentation(for: message.id) } onChange: { changed.withLock { $0 = true } }
        for revision in 1...10 {
            message.text = "Payload revision \(revision)"
            await store.prepare([message])
        }
        #expect(!changed.withLock { $0 })
        #expect(store[message.id]?.sourceText == "Payload revision 10")
        store.trim(keeping: [])
        #expect(changed.withLock { $0 })
        #expect(!store.hasPresentation(for: message.id))
        store.retire()
    }

    @Test func inlineUserRowsUseTheWorkerOnceAndKeepTheirPreparedPresentation() async {
        let requests = Mutex<[UUID]>([])
        let store = RenderedMessageStore(renderer: { input in
            requests.withLock { $0.append(contentsOf: input.map(\.id)) }
            var highlighting = SyntaxHighlightCache()
            return input.map { ($0.id, RenderedMessage.render(text: $0.text, inline: $0.inline,
                isStreaming: $0.isStreaming, previous: $0.previous, highlighting: &highlighting)) }
        })
        let paste = PastedTextPromptBlock.Entry(id: UUID(), text: "paste")
        let inline = InlineMessageContent(.init(runs: [.text("**before** "), .paste(paste), .text(" after")]))
        let message = ChatMessage(role: .user, text: "before  after", inlineContent: inline)
        await store.prepareOpening([message])
        await store.prepareMounting([message])
        await store.prepare([message])
        #expect(store.hasOpeningRendered([message]))
        #expect(store.hasRendered([message]))
        #expect(requests.withLock { $0 } == [message.id])
        #expect(store[message.id]?.inline?.source == inline)
        #expect(store[message.id]?.blocks.isEmpty == true)
        if case .text(let text) = store[message.id]?.inline?.runs.first {
            #expect(String(text.characters) == "before ")
        } else {
            Issue.record("The worker must prepare the inline typed run")
        }
        var changed = message
        let replacement = InlineMessageContent(.init(runs: [.text("*before* "), .paste(paste), .text(" after")]))
        changed.inlineContent = replacement
        await store.prepare([changed])
        #expect(requests.withLock { $0 } == [message.id, message.id])
        #expect(store[message.id]?.inline?.source == replacement)
        store.retire()
    }

    @Test func oneStreamingMessageInvalidatesOnlyItsOwnReader() async {
        let store = RenderedMessageStore()
        var messages = (0..<200).map {
            ChatMessage(role: .codex, text: "Message \($0)", isStreaming: true)
        }
        await store.prepare(messages)
        let changed = Mutex<[UUID]>([])
        for message in messages {
            withObservationTracking { _ = store[message.id] } onChange: {
                changed.withLock { $0.append(message.id) }
            }
        }
        messages[199].text += " next chunk"
        await store.prepare([messages[199]])
        #expect(changed.withLock { $0 } == [messages[199].id])
        #expect(store[messages[199].id]?.sourceText == messages[199].text)
        Attachment.record("200 observed messages; 1 changed message; \(changed.withLock { $0.count }) invalidated reader(s).",
                          named: "render-observation-count.txt")
    }

    @Test func anUnchangedRequestDoesNotInvalidateItsReader() async {
        let store = RenderedMessageStore()
        let message = ChatMessage(role: .codex, text: "Unchanged")
        await store.prepare([message])
        let changed = Mutex(false)
        withObservationTracking { _ = store[message.id] } onChange: { changed.withLock { $0 = true } }
        await store.prepare([message])
        #expect(!changed.withLock { $0 })
    }

    @Test func aReaderWaitingForItsFirstPresentationIsNotified() async {
        let store = RenderedMessageStore()
        let message = ChatMessage(role: .codex, text: "First render")
        let changed = Mutex(false)
        withObservationTracking { _ = store[message.id] } onChange: { changed.withLock { $0 = true } }
        await store.prepare([message])
        #expect(changed.withLock { $0 })
        #expect(store[message.id]?.sourceText == message.text)
    }

    @Test func otherMessagesArrivingOrLeavingDoNotInvalidateAReader() async {
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        let visible = message(bytes: 1)
        await store.prepare([visible, message(bytes: 1)])
        let changed = Mutex(false)
        withObservationTracking { _ = store[visible.id] } onChange: { changed.withLock { $0 = true } }
        await store.prepare([message(bytes: 1)])
        store.trim(keeping: [visible.id])
        #expect(!changed.withLock { $0 })
    }

    @Test func aReaderWhoseEntryIsEvictedSeesItsNextRender() async {
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        let waiting = message(bytes: 1)
        let evicted = Mutex(false)
        withObservationTracking { _ = store[waiting.id] } onChange: { evicted.withLock { $0 = true } }
        await store.prepare((0..<2_000).map { _ in message(bytes: 1) })
        #expect(evicted.withLock { $0 })
        let rendered = Mutex(false)
        withObservationTracking { _ = store[waiting.id] } onChange: { rendered.withLock { $0 = true } }
        await store.prepare([waiting])
        #expect(rendered.withLock { $0 })
        #expect(store[waiting.id]?.sourceText == waiting.text)
    }

    @Test func presentedWindowSurvivesWarmingBeyondTheReusableBudget() async {
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        let presented = [message(bytes: 4 * 1_024 * 1_024), message(bytes: 4 * 1_024 * 1_024)]
        store.retainPresented(Set(presented.map(\.id)))
        await store.prepare(presented)
        let initiallyReady = store.hasRendered(presented)
        #expect(initiallyReady)
        let changed = Mutex(false)
        withObservationTracking { _ = store[presented[0].id] } onChange: { changed.withLock { $0 = true } }
        let warmed = (0..<3).map { _ in message(bytes: 4 * 1_024 * 1_024) }
        await store.prepare(warmed)
        let readyAfterWarming = store.hasRendered(presented)
        #expect(readyAfterWarming)
        #expect(!changed.withLock { $0 })
        #expect(store[warmed[0].id] == nil)
        #expect(store[warmed[1].id] != nil)
        #expect(store[warmed[2].id] != nil)
        store.trim(keeping: Set(warmed.map(\.id)))
        let readyAfterTrimming = store.hasRendered(presented)
        #expect(readyAfterTrimming)
        #expect(!changed.withLock { $0 })
        store.retainPresented([])
        #expect(store[presented[0].id] == nil)
        #expect(store[presented[1].id] == nil)
        #expect(store[warmed[1].id] != nil)
        #expect(store[warmed[2].id] != nil)
    }

    @Test func oversizedPresentedMessageStaysReadyWithoutReparsing() async {
        let renders = Mutex(0)
        let store = RenderedMessageStore(renderer: { input in
            renders.withLock { $0 += input.count }
            return await Self.rawRenderer(input)
        })
        let oversized = message(bytes: 9 * 1_024 * 1_024)
        store.retainPresented([oversized.id])
        await store.prepareMounting([oversized])
        let mountingReady = store.hasRendered([oversized])
        let openingReady = store.hasOpeningRendered([oversized])
        #expect(mountingReady)
        #expect(openingReady)
        await store.prepare([oversized])
        await store.prepareMounting([oversized])
        #expect(renders.withLock { $0 } == 1)
        let sourceMatches = store[oversized.id]?.sourceText == oversized.text
        #expect(sourceMatches)
        store.retainPresented([])
        #expect(store[oversized.id] == nil)
    }

    @Test func replacementBytesAreSubtractedBeforeApplyingTheCacheBudget() async {
        // The injected renderer isolates cache policy from parsing multi-megabyte Markdown.
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        let mb = 1_024 * 1_024
        let first = message(bytes: 3 * mb)
        var second = message(bytes: 3 * mb)
        let third = message(bytes: 3 * mb)
        await store.prepare([first, second, third])
        #expect(store[first.id] == nil)
        #expect(store[second.id] != nil)
        second.text = String(repeating: "b", count: mb)
        await store.prepare([second])
        let fourth = message(bytes: 4 * mb)
        await store.prepare([fourth])
        #expect(store[second.id] != nil)
        #expect(store[third.id] != nil)
        #expect(store[fourth.id] != nil)
        let fifth = message(bytes: 1)
        await store.prepare([fifth])
        #expect(store[second.id] == nil)
        #expect(store[third.id] != nil)
        #expect(store[fourth.id] != nil)
        #expect(store[fifth.id] != nil)
    }

    @Test func entryCountIsBoundedAndRetirementReleasesTheCache() async {
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        let messages = (0..<2_001).map { _ in message(bytes: 1) }
        await store.prepare(messages)
        #expect(store[messages[0].id] == nil)
        #expect(store[messages[1].id] != nil)
        #expect(store[messages[2_000].id] != nil)
        store.retire()
        #expect(store[messages[2_000].id] == nil)
    }

    @Test func trimmingAnAlreadyMinimalCacheDoesNotInvalidateTheVisibleReader() async {
        let store = RenderedMessageStore()
        let visible = message(bytes: 100)
        await store.prepare([visible])
        let changed = Mutex(false)
        withObservationTracking { _ = store[visible.id] } onChange: { changed.withLock { $0 = true } }
        store.trim(keeping: [visible.id])
        #expect(!changed.withLock { $0 })
    }

    @Test func trimmingUpdatesTheByteBudgetForSubsequentRenders() async {
        let store = RenderedMessageStore(renderer: Self.rawRenderer)
        let first = message(bytes: 4 * 1_024 * 1_024)
        let second = message(bytes: 4 * 1_024 * 1_024)
        await store.prepare([first, second])
        store.trim(keeping: [second.id])
        let third = message(bytes: 4 * 1_024 * 1_024)
        await store.prepare([third])
        #expect(store[first.id] == nil)
        #expect(store[second.id] != nil)
        #expect(store[third.id] != nil)
    }

    @Test(.timeLimit(.minutes(1))) func tailDeadlineDoesNotAwaitAnUncooperativeRenderer() async {
        let gate = StreamingRenderGate()
        await gate.block()
        let store = RenderedMessageStore(renderer: { await gate.render($0) })
        let message = ChatMessage(role: .codex, text: "**Waiting", isStreaming: true)
        await store.prepareTail([message])
        #expect(store[message.id] == nil)
        await gate.release()
        await store.prepare([message])
        #expect(store[message.id]?.sourceText == message.text)
    }

    @Test(.timeLimit(.minutes(1))) func openingWaitsForTheLatestMessagesBeforeEarlierQueuedWork() async {
        let gate = StreamingRenderGate()
        let store = RenderedMessageStore(renderer: { await gate.render($0) })
        let messages = (0..<48).map { ChatMessage(role: .codex, text: "**Reply \($0)**") }
        store.ensureRendered(Array(messages.prefix(40)))
        await store.prepareOpening(messages)
        #expect(store.hasOpeningRendered(messages))
        #expect(await gate.batches.first.map { Array($0.prefix(8)) } == messages.suffix(8).map(\.id))
    }

    @Test(.timeLimit(.minutes(1))) func openingDeadlineDoesNotAwaitAnUncooperativeRenderer() async {
        let gate = StreamingRenderGate()
        await gate.block()
        let store = RenderedMessageStore(renderer: { await gate.render($0) })
        let message = ChatMessage(role: .codex, text: "Completed history")
        await store.prepareOpening([message])
        #expect(!store.hasOpeningRendered([message]))
        await gate.release()
        await store.prepare([message])
        #expect(store.hasOpeningRendered([message]))
    }

    @Test func terminalStateIsRenderedEvenWhenTextDidNotChange() async {
        let store = RenderedMessageStore()
        var message = ChatMessage(role: .codex, text: "**unfinished", isStreaming: true)
        await store.prepare([message])
        #expect(store[message.id]?.blocks.first?.inlines.first?.characters.contains("*") == false)
        message.isStreaming = false
        await store.prepare([message])
        #expect(store[message.id]?.isStreaming == false)
        #expect(store[message.id]?.blocks.first?.inlines.first?.characters.contains("*") == true)
    }

    @Test func memoryPressureKeepsLastGoodContentAndDoesNotCancelItsReplacement() async {
        let gate = StreamingRenderGate()
        let store = RenderedMessageStore(renderer: { await gate.render($0) })
        var visible = ChatMessage(role: .codex, text: "Old", isStreaming: true)
        let cached = ChatMessage(role: .codex, text: "Cached history")
        await store.prepare([visible, cached])
        await gate.block()
        visible.text = "New"
        store.ensureRendered([visible])
        await gate.waitForStart()
        store.trim(keeping: [visible.id])
        #expect(store[cached.id] == nil)
        #expect(store[visible.id]?.sourceText == "Old")
        await gate.release()
        await store.prepare([visible])
        #expect(store[visible.id]?.sourceText == "New")
        // Revisiting discarded history is still a normal cache miss, not retirement.
        await store.prepare([cached])
        #expect(store[cached.id]?.sourceText == cached.text)
    }

    @Test func retirementRejectsLateWork() async {
        let gate = StreamingRenderGate()
        await gate.block()
        let store = RenderedMessageStore(renderer: { await gate.render($0) })
        let message = ChatMessage(role: .codex, text: "Late", isStreaming: true)
        let prepare = Task { await store.prepare([message]) }
        await gate.waitForStart()
        store.retire()
        await gate.release()
        await prepare.value
        #expect(store[message.id] == nil)
    }

    @Test func obsoleteRenderCannotPublishAfterNewTextWasRequested() async {
        let gate = StreamingRenderGate()
        await gate.block()
        let store = RenderedMessageStore(renderer: { await gate.render($0) })
        var message = ChatMessage(role: .codex, text: "Old")
        let task = Task { await store.prepare([message]) }
        await gate.waitForStart()
        message.text = "New"
        store.ensureRendered([message])
        await gate.release()
        await task.value
        #expect(store[message.id]?.sourceText == "New")
        #expect(await gate.maximumConcurrent == 1)
    }

    private func message(bytes: Int) -> ChatMessage {
        ChatMessage(role: .codex, text: String(repeating: "a", count: bytes))
    }

    nonisolated private static let rawRenderer: RenderedMessageStore.Renderer = { input in
        input.map { ($0.id, RenderedMessage(sourceText: $0.text, sourceBytes: ($0.inline?.plainText ?? $0.text).utf8.count, isStreaming: $0.isStreaming,
            extendsStream: false, body: $0.text, document: .empty, inline: $0.inline.map(RenderedInlineMessage.init), revision: ($0.previous?.revision ?? 0) + 1)) }
    }
}

private actor StreamingRenderGate {
    private var blocked = false
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    private(set) var batches: [[UUID]] = []

    func block() { blocked = true; started = false }
    func render(_ input: [RenderedMessageStore.Input]) async -> [(UUID, RenderedMessage)] {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        batches.append(input.map(\.id))
        if blocked {
            started = true
            startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        var highlighting = SyntaxHighlightCache()
        return input.map { ($0.id, RenderedMessage.render(text: $0.text, inline: $0.inline, isStreaming: $0.isStreaming,
            previous: $0.previous, highlighting: &highlighting)) }
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { blocked = false; releaseWaiter?.resume(); releaseWaiter = nil }
}
