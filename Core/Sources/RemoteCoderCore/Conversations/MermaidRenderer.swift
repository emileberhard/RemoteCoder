import Foundation

struct MermaidRequest: Hashable, Sendable {
    let source: String
    let isDark: Bool
    let highContrast: Bool
}

struct MermaidDiagram: Sendable {
    let svg: String
    let preview: Data
    let size: CGSize
    let title: String
    let summary: String
    let background: String

    var byteCount: Int {
        svg.utf8.count + preview.count + title.utf8.count + summary.utf8.count + background.utf8.count
    }
}

struct MermaidFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum MermaidAdmissionError: Error, Sendable {
    case busy
}

/// An app-wide, memory-only illustration cache, independent of transcript state.
/// One WebKit session drains visible requests serially; rows never own web views.
/// Cancelling a subscriber releases it immediately, not after JavaScript finishes.
@MainActor
final class MermaidRenderer {
    typealias Render = @MainActor (MermaidRequest) async throws -> MermaidDiagram
    typealias Outcome = Result<MermaidDiagram, MermaidFailure>
    private typealias Waiter = CheckedContinuation<MermaidDiagram, any Error>

    static let maxSourceBytes = 32_768
    static let maxQueuedRequests = 16
    static let maxSubscribers = 64
    private let makeRender: () -> Render
    private let cacheLimit: Int
    private let byteLimit: Int
    private var cache: [MermaidRequest: Outcome] = [:]
    private var recency: [MermaidRequest] = []
    private var cacheBytes = 0
    private var aspectRatios: [MermaidRequest: CGFloat] = [:]
    private var aspectRecency: [MermaidRequest] = []
    private var subscribers: [MermaidRequest: [UUID: Waiter]] = [:]
    private var queue: [MermaidRequest] = []
    private var active: MermaidRequest?
    private var worker: Task<Void, Never>?

    /// The factory makes session lifetime and non-cooperative rendering testable.
    init(cacheLimit: Int, byteLimit: Int, makeRender: @escaping () -> Render) {
        self.cacheLimit = cacheLimit
        self.byteLimit = byteLimit
        self.makeRender = makeRender
    }

    func aspectRatio(for request: MermaidRequest) -> CGFloat? {
        guard let aspect = aspectRatios[request] else { return nil }
        aspectRecency.removeAll { $0 == request }
        aspectRecency.append(request)
        return aspect
    }

    func diagram(for request: MermaidRequest) async throws -> MermaidDiagram {
        try Task.checkCancellation()
        guard request.source.utf8.count <= Self.maxSourceBytes else {
            throw MermaidFailure(message: "This diagram exceeds the 32 KB preview limit. Its source is still available.")
        }
        if let value = cache[request] {
            touch(request)
            return try value.get()
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard subscribers.values.reduce(0, { $0 + $1.count }) < Self.maxSubscribers,
                      subscribers[request] != nil || queue.count < Self.maxQueuedRequests else {
                    continuation.resume(throwing: MermaidAdmissionError.busy)
                    return
                }
                if subscribers[request] == nil {
                    subscribers[request] = [:]
                    queue.append(request)
                }
                subscribers[request]?[id] = continuation
                if worker == nil { worker = Task { await drain() } }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id, request: request) }
        }
    }

    /// Memory pressure discards reusable results, not visible row-owned images
    /// or the subscribers of a render that is already in flight.
    func removeCachedDiagrams() {
        cache.removeAll()
        recency.removeAll()
        cacheBytes = 0
    }

    func invalidate(_ request: MermaidRequest) {
        if let old = cache.removeValue(forKey: request) { cacheBytes -= cost(old, request: request) }
        recency.removeAll { $0 == request }
    }

    private func cancel(_ id: UUID, request: MermaidRequest) {
        subscribers[request]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if subscribers[request]?.isEmpty == true, active != request {
            subscribers.removeValue(forKey: request)
            queue.removeAll { $0 == request }
        }
        // An active, input-bounded JS render can finish, but has no cancelled subscribers
        // to publish to. Keep its slot until completion: never spawn parallel pages.
    }

    private func drain() async {
        let render = makeRender()
        defer { active = nil; worker = nil } // Releases the WebPage when this batch is idle.
        while !queue.isEmpty {
            let request = queue.removeFirst()
            guard subscribers[request]?.isEmpty == false else {
                subscribers.removeValue(forKey: request)
                continue
            }
            active = request
            let outcome: Outcome
            do { outcome = .success(try await render(request)) }
            catch let failure as MermaidFailure { outcome = .failure(failure) }
            catch {
                let error = error as NSError
                let detail = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                outcome = .failure(MermaidFailure(message: String(detail.prefix(600))))
            }
            let waiters = subscribers.removeValue(forKey: request)?.values
            active = nil
            // A retired/offscreen request need not retain its content in the cache.
            if let waiters, !waiters.isEmpty {
                store(outcome, request: request)
                for waiter in waiters { waiter.resume(with: outcome.mapError { $0 as any Error }) }
            }
        }
    }

    private func touch(_ request: MermaidRequest) {
        recency.removeAll { $0 == request }
        recency.append(request)
    }

    private func cost(_ outcome: Outcome, request: MermaidRequest) -> Int {
        let valueBytes: Int
        switch outcome {
        case .success(let diagram): valueBytes = diagram.byteCount
        case .failure(let failure): valueBytes = failure.message.utf8.count
        }
        return request.source.utf8.count + valueBytes
    }

    private func store(_ outcome: Outcome, request: MermaidRequest) {
        invalidate(request)
        if case .success(let diagram) = outcome {
            aspectRatios[request] = diagram.size.width / diagram.size.height
            aspectRecency.removeAll { $0 == request }
            aspectRecency.append(request)
            if aspectRecency.count > 256 { aspectRatios.removeValue(forKey: aspectRecency.removeFirst()) }
        }
        let bytes = cost(outcome, request: request)
        guard bytes <= byteLimit, cacheLimit > 0 else { return }
        cache[request] = outcome
        cacheBytes += bytes
        touch(request)
        while cache.count > cacheLimit || cacheBytes > byteLimit {
            guard let oldest = recency.first else { break }
            invalidate(oldest)
        }
    }
}
