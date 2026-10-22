import Foundation

/// One worker owns parsing and highlighting. Obsolete work may finish, but can
/// never overwrite a newer request or publish after retirement.
@MainActor
final class RenderedMessageStore {
    weak var retainedTranscripts: TranscriptSurfaceRetention?
    struct Input: Sendable {
        let id: UUID
        let text: String
        let inline: InlineMessageContent?
        let isStreaming: Bool
        let previous: RenderedMessage?
    }
    typealias Renderer = @Sendable ([Input]) async -> [(UUID, RenderedMessage)]
    private struct Request: Equatable { let text: String; let inline: InlineMessageContent?; let isStreaming: Bool }

    private typealias Entry = RenderedMessageEntry<RenderedMessage>

    // Readers observe only their own entry, so a render, insertion or eviction
    // invalidates only the bubbles showing that message.
    private var entries: [UUID: Entry] = [:]
    private var sourceBytes = 0
    private var presentedIDs: Set<UUID> = []

    subscript(id: UUID) -> RenderedMessage? { entry(id).rendered }
    func hasPresentation(for id: UUID) -> Bool { entry(id).isPresent }
    private var insertionOrder: [UUID] = []
    private var requested: [UUID: Request] = [:]
    private var pending: [UUID: Request] = [:]
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var retired = false
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let renderer: Renderer
    private static let maxEntries = 2_000
    private static let openingMessageCount = 8
    private static let maxSourceBytes = 8 * 1_024 * 1_024

    init() {
        let rendering = MarkdownRenderWorker()
        renderer = { await rendering.render($0) }
    }

    init(renderer: @escaping Renderer) { self.renderer = renderer }

    func prepare(_ messages: [ChatMessage]) async {
        ensureRendered(messages)
        await worker?.value
    }

    func prepareTail(_ messages: [ChatMessage]) async {
        await awaitRenders(of: messages.filter { $0.isStreaming && !isRendered($0) }, atMost: .milliseconds(50))
    }

    func prepareOpening(_ messages: [ChatMessage]) async {
        await awaitRenders(of: messages.suffix(Self.openingMessageCount).filter { !isRendered($0) },
            atMost: .milliseconds(150))
    }

    func hasOpeningRendered(_ messages: [ChatMessage]) -> Bool {
        messages.suffix(Self.openingMessageCount).allSatisfy { isRendered($0) }
    }

    func prepareMounting(_ messages: [ChatMessage]) async {
        await awaitRenders(of: Array(messages.filter { !isRendered($0) }.prefix(32)),
            atMost: TranscriptReadingRestoration.renderReadinessTimeout)
    }

    func hasRendered(_ messages: [ChatMessage]) -> Bool {
        tailIsReady(messages)
    }

    func htmlVisualReferences(in messages: some Sequence<ChatMessage>) -> [HTMLVisualReference] {
        messages.flatMap { message -> [HTMLVisualReference] in
            guard let rendered = entries[message.id]?.rendered, rendered.containsHTMLVisual else { return [] }
            return rendered.blocks.compactMap { block in
                guard case .htmlVisual(let url, _) = block.content else { return nil }
                return HTMLVisualReference(url: url)
            }
        }
    }

    func htmlVisualReferences(in rows: some Sequence<TranscriptRow>) -> [HTMLVisualReference] {
        rows.flatMap { row -> [HTMLVisualReference] in
            if case .content(.publishedVisual(let visual)) = row.kind { return [visual.publication.reference] }
            guard let message = row.message else { return [] }
            return htmlVisualReferences(in: [message])
        }
    }

    /// The timeout races a cancellable notification stream, not the rendering
    /// worker. A renderer that ignores cancellation cannot hold up publication.
    private func awaitRenders(of missing: [ChatMessage], atMost deadline: Duration) async {
        guard !retired, !missing.isEmpty, missing.count <= 32 else { return }
        ensureRendered(missing)
        let urgent = Set(missing.map(\.id))
        queue = queue.filter(urgent.contains) + queue.filter { !urgent.contains($0) }
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[id] = continuation
        defer { waiters.removeValue(forKey: id)?.finish() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in events {
                    if await self.tailIsReady(missing) { return }
                }
            }
            group.addTask { try? await Task.sleep(for: deadline) }
            await group.next()
            group.cancelAll()
        }
    }

    private func tailIsReady(_ messages: [ChatMessage]) -> Bool {
        retired || messages.allSatisfy { isRendered($0) }
    }

    private func isRendered(_ message: ChatMessage) -> Bool {
        entries[message.id]?.rendered != nil
    }

    private func entry(_ id: UUID) -> Entry {
        if let entry = entries[id] { return entry }
        let entry = Entry()
        entries[id] = entry
        insertionOrder.append(id)
        return entry
    }

    private func remove(_ id: UUID) {
        retainedTranscripts?.prepareRenderChange(id, in: ObjectIdentifier(self))
        guard let entry = entries.removeValue(forKey: id) else { return }
        sourceBytes -= entry.sourceBytes
        entry.replace(with: nil)
    }

    func ensureRendered(_ messages: [ChatMessage]) {
        guard !retired else { return }
        for message in messages {
            let request = Request(text: message.text, inline: message.inlineContent, isStreaming: message.isStreaming)
            if let rendered = entries[message.id]?.rendered, rendered.sourceText == request.text,
               rendered.inline?.source == request.inline,
               rendered.isStreaming == request.isStreaming {
                requested.removeValue(forKey: message.id)
                pending.removeValue(forKey: message.id)
                continue
            }
            guard requested[message.id] != request else { continue }
            requested[message.id] = request
            if pending[message.id] == nil { queue.append(message.id) }
            pending[message.id] = request
        }
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { await drain() }
    }

    /// Drop reusable presentations, never the visible conversation's last-good
    /// values or pending renders. An in-flight user request may still complete.
    func trim(keeping ids: Set<UUID>) {
        let ids = ids.union(presentedIDs)
        let removed = insertionOrder.filter { !ids.contains($0) }
        guard !removed.isEmpty else { return }
        removed.forEach(remove)
        insertionOrder.removeAll { !ids.contains($0) }
    }

    func retainPresented(_ ids: Set<UUID>) {
        presentedIDs = ids
        evictIfNeeded()
    }

    func retire() {
        retainedTranscripts?.retireRenderStore(ObjectIdentifier(self))
        retired = true
        worker?.cancel()
        for entry in entries.values { entry.replace(with: nil) }
        entries.removeAll()
        insertionOrder.removeAll()
        sourceBytes = 0
        presentedIDs.removeAll()
        requested.removeAll()
        pending.removeAll()
        queue.removeAll()
        for waiter in waiters.values { waiter.finish() }
        waiters.removeAll()
    }

    private func drain() async {
        defer { worker = nil }
        while !queue.isEmpty && !Task.isCancelled {
            let ids = Array(queue.prefix(32))
            queue.removeFirst(ids.count)
            let input = ids.compactMap { id -> Input? in
                guard let request = pending.removeValue(forKey: id) else { return nil }
                return Input(id: id, text: request.text, inline: request.inline, isStreaming: request.isStreaming,
                             previous: entries[id]?.rendered)
            }
            guard !input.isEmpty else { continue }
            let rendered = await renderer(input)
            guard !retired, !Task.isCancelled else { return }
            let span = PerfBuild.span("render.publish"); defer { span.end() }
            for (id, message) in rendered {
                guard let request = requested[id], request.text == message.sourceText,
                      request.inline == message.inline?.source,
                      request.isStreaming == message.isStreaming else { continue }
                let entry = self.entry(id)
                retainedTranscripts?.prepareRenderChange(id, in: ObjectIdentifier(self))
                let bytes = message.sourceBytes
                sourceBytes += bytes - entry.sourceBytes
                entry.sourceBytes = bytes
                #if RC_PERF_HARNESS
                PerfBuild.count("renderPublish")
                #endif
                entry.replace(with: message)
                requested.removeValue(forKey: id)
            }
            evictIfNeeded()
            for waiter in waiters.values { waiter.yield() }
        }
    }

    private func evictIfNeeded() {
        guard entries.count > Self.maxEntries || sourceBytes > Self.maxSourceBytes else { return }
        var reusableCount = entries.count
        var reusableBytes = sourceBytes
        for id in presentedIDs {
            guard let entry = entries[id] else { continue }
            reusableCount -= 1
            reusableBytes -= entry.sourceBytes
        }
        var removed: Set<UUID> = []
        for id in insertionOrder {
            guard reusableCount > Self.maxEntries || reusableBytes > Self.maxSourceBytes else { break }
            guard !presentedIDs.contains(id), let entry = entries[id] else { continue }
            reusableCount -= 1
            reusableBytes -= entry.sourceBytes
            remove(id)
            removed.insert(id)
        }
        insertionOrder.removeAll { removed.contains($0) }
    }
}

private actor MarkdownRenderWorker {
    private var highlighting = SyntaxHighlightCache()

    func render(_ input: [RenderedMessageStore.Input]) -> [(UUID, RenderedMessage)] {
        input.map { ($0.id, RenderedMessage.render(text: $0.text, inline: $0.inline, isStreaming: $0.isStreaming,
            previous: $0.previous, highlighting: &highlighting)) }
    }
}
