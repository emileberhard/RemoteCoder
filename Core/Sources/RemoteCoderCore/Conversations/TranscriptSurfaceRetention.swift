import Foundation

@MainActor
protocol RetainedTranscriptSurface: AnyObject {
    var renderStoreID: ObjectIdentifier? { get }
    func discardRetainedSurface()
    func observesRenderedMessage(_ id: UUID, in store: ObjectIdentifier) -> Bool
}

@MainActor
final class TranscriptSurfaceRetention {
    @MainActor
    struct Scope {
        fileprivate let id: UUID
        weak var cache: TranscriptSurfaceRetention?

        func surface(for position: TranscriptReadingPosition) -> (any RetainedTranscriptSurface)? {
            cache?.surface(for: position, scope: id)
        }

        func take(for position: TranscriptReadingPosition) -> (any RetainedTranscriptSurface)? {
            cache?.take(for: position, scope: id)
        }

        func retain(_ surface: any RetainedTranscriptSurface, for position: TranscriptReadingPosition) -> Bool {
            guard let cache else { return false }
            cache.retain(surface, for: position, scope: id)
            return true
        }
    }

    private struct Key: Hashable {
        let position: ObjectIdentifier
        let scope: UUID
    }
    private struct Entry {
        weak var position: TranscriptReadingPosition?
        let surface: any RetainedTranscriptSurface
    }

    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    nonisolated static func hasQuiescentContent(_ item: ChatStreamItem, historyEdgeStatus: HistoryEdge.Status?) -> Bool {
        switch item {
        case .question: false
        case .message(let message): !message.isStreaming
        case .timeline(let timeline): !timeline.isLive
        case .compaction(let marker): !marker.compaction.isActive
        case .historyEdge: historyEdgeStatus != .loading
        case .turnOutcome, .viewedMedia, .publishedVisual: true
        }
    }

    func scope(owner: UUID) -> Scope { Scope(id: owner, cache: self) }

    private func surface(for position: TranscriptReadingPosition, scope: UUID) -> (any RetainedTranscriptSurface)? {
        prune()
        let id = Key(position: ObjectIdentifier(position), scope: scope)
        guard let entry = entries[id] else { return nil }
        recency.removeAll { $0 == id }
        recency.append(id)
        return entry.surface
    }

    var count: Int {
        prune()
        return entries.count
    }

    private func take(for position: TranscriptReadingPosition, scope: UUID) -> (any RetainedTranscriptSurface)? {
        prune()
        let id = Key(position: ObjectIdentifier(position), scope: scope)
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        recency.removeAll { $0 == id }
        if !recency.contains(where: { $0.position == id.position }) { position.releaseSurfaceRetention(self) }
        return entry.surface
    }

    private func retain(_ surface: any RetainedTranscriptSurface, for position: TranscriptReadingPosition, scope: UUID) {
        prune()
        let id = Key(position: ObjectIdentifier(position), scope: scope)
        remove(id)
        entries[id] = Entry(position: position, surface: surface)
        recency.append(id)
        position.addSurfaceRetention(self)
        while recency.count > capacity {
            if let oldest = recency.first { remove(oldest) }
        }
    }

    func invalidate(_ position: TranscriptReadingPosition) {
        let id = ObjectIdentifier(position)
        for key in recency where key.position == id { remove(key) }
    }

    func prepareRenderChange(_ id: UUID, in store: ObjectIdentifier) {
        invalidate { $0.observesRenderedMessage(id, in: store) }
    }

    func retireRenderStore(_ store: ObjectIdentifier) {
        invalidate { $0.renderStoreID == store }
    }

    func invalidate(where predicate: (any RetainedTranscriptSurface) -> Bool) {
        for id in recency where entries[id].map({ predicate($0.surface) }) == true { remove(id) }
    }

    func removeAll() {
        for id in recency { remove(id) }
    }

    private func prune() {
        for id in recency where entries[id]?.position == nil { remove(id) }
    }

    private func remove(_ id: Key) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        recency.removeAll { $0 == id }
        if !recency.contains(where: { $0.position == id.position }) { entry.position?.releaseSurfaceRetention(self) }
        entry.surface.discardRetainedSurface()
    }
}
