import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct MermaidQueueTests {
    private func request(_ source: String, dark: Bool = false) -> MermaidRequest {
        MermaidRequest(source: source, isDark: dark, highContrast: false)
    }

    @Test func rejectsQueueOverflowAndAllowsRetryAfterDraining() async throws {
        let gate = MermaidTestGate()
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: { { try await gate.render($0) } })
        let first = Task { try await renderer.diagram(for: request("active")) }
        await gate.waitForStart()
        var pending: [Task<MermaidDiagram, any Error>] = []
        for index in 0...MermaidRenderer.maxQueuedRequests {
            let registered = AsyncStream<Void>.makeStream()
            pending.append(Task {
                registered.continuation.yield(())
                return try await renderer.diagram(for: request("queued-\(index)"))
            })
            var iterator = registered.stream.makeAsyncIterator()
            _ = await iterator.next(isolation: #isolation)
        }
        gate.releaseAll()
        _ = try await first.value
        for task in pending.dropLast() { _ = try await task.value }
        let overflow = try #require(pending.last)
        await #expect(throws: MermaidAdmissionError.busy) { try await overflow.value }
        let retry = request("queued-\(MermaidRenderer.maxQueuedRequests)")
        _ = try await renderer.diagram(for: retry)
        #expect(gate.requests.last == retry)
        #expect(gate.requests.count == MermaidRenderer.maxQueuedRequests + 2)
    }

    @Test func boundsSubscribersEvenWhenTheyShareOneRequest() async throws {
        let gate = MermaidTestGate()
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: { { try await gate.render($0) } })
        let input = request("shared")
        let first = Task { try await renderer.diagram(for: input) }
        await gate.waitForStart()
        var pending: [Task<MermaidDiagram, any Error>] = []
        for _ in 0..<MermaidRenderer.maxSubscribers {
            let registered = AsyncStream<Void>.makeStream()
            pending.append(Task {
                registered.continuation.yield(())
                return try await renderer.diagram(for: input)
            })
            var iterator = registered.stream.makeAsyncIterator()
            _ = await iterator.next(isolation: #isolation)
        }
        gate.releaseAll()
        _ = try await first.value
        for task in pending.dropLast() { _ = try await task.value }
        let overflow = try #require(pending.last)
        await #expect(throws: MermaidAdmissionError.busy) { try await overflow.value }
        #expect(gate.requests == [input])
    }

    @Test func coalescesAndDoesNotCancelAnotherSubscriber() async throws {
        let gate = MermaidTestGate()
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: { { try await gate.render($0) } })
        let input = request("one")
        let first = Task { try await renderer.diagram(for: input) }
        await gate.waitForStart()
        let second = Task { try await renderer.diagram(for: input) }
        // Let the second subscriber register while the external renderer is blocked.
        await Task.yield()
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled subscriber received a result") }
        catch is CancellationError { }
        gate.release()
        _ = try await second.value
        #expect(gate.requests == [input])
        _ = try await renderer.diagram(for: input)
        #expect(gate.requests.count == 1)
    }

    @Test func cancelledQueuedWorkNeverStarts() async throws {
        let gate = MermaidTestGate()
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: { { try await gate.render($0) } })
        let first = Task { try await renderer.diagram(for: request("one")) }
        await gate.waitForStart()
        let second = Task { try await renderer.diagram(for: request("two")) }
        await Task.yield()
        second.cancel()
        do { _ = try await second.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        gate.release()
        _ = try await first.value
        #expect(gate.requests.map(\.source) == ["one"])
    }

    @Test func serializesDifferentSourcesAndReleasesTheIdleSession() async throws {
        let gate = MermaidTestGate()
        var sessions = 0
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: {
            sessions += 1
            return { try await gate.render($0) }
        })
        let first = Task { try await renderer.diagram(for: request("one")) }
        await gate.waitForStart()
        let second = Task { try await renderer.diagram(for: request("two")) }
        await Task.yield()
        #expect(gate.requests.count == 1)
        gate.release()
        _ = try await first.value
        await gate.waitForStart()
        #expect(gate.requests.count == 2)
        #expect(sessions == 1)
        gate.release()
        _ = try await second.value
        // A cache miss after draining starts a fresh bounded session.
        let third = Task { try await renderer.diagram(for: request("three")) }
        await gate.waitForStart()
        #expect(sessions == 2)
        gate.release()
        _ = try await third.value
    }

    @Test func cacheKeysIncludeAppearanceAndEvictionIsLeastRecent() async throws {
        var rendered: [MermaidRequest] = []
        let renderer = MermaidRenderer(cacheLimit: 2, byteLimit: 4096, makeRender: {
            { request in rendered.append(request); return MermaidTestGate.value(request.source) }
        })
        let a = request("a"), b = request("b"), darkA = request("a", dark: true)
        _ = try await renderer.diagram(for: a)
        _ = try await renderer.diagram(for: b)
        _ = try await renderer.diagram(for: a) // a becomes most recent.
        _ = try await renderer.diagram(for: darkA) // evicts b, not a.
        _ = try await renderer.diagram(for: a)
        _ = try await renderer.diagram(for: b)
        #expect(rendered == [a, b, darkA, b])
    }

    @Test func byteBudgetAndOversizedInputAreEnforced() async throws {
        var count = 0
        let renderer = MermaidRenderer(cacheLimit: 32, byteLimit: 1, makeRender: {
            { request in count += 1; return MermaidTestGate.value(request.source) }
        })
        _ = try await renderer.diagram(for: request("a"))
        _ = try await renderer.diagram(for: request("a"))
        #expect(count == 2)
        await #expect(throws: MermaidFailure.self) {
            try await renderer.diagram(for: request(String(repeating: "Å", count: MermaidRenderer.maxSourceBytes)))
        }
        #expect(count == 2)
    }

    @Test func memoryPressureDiscardsCachedResultsAndResetsTheirBudget() async throws {
        var rendered: [MermaidRequest] = []
        let renderer = MermaidRenderer(cacheLimit: 2, byteLimit: 40, makeRender: {
            { request in rendered.append(request); return MermaidTestGate.value(request.source) }
        })
        let a = request("a"), b = request("b")
        _ = try await renderer.diagram(for: a)
        _ = try await renderer.diagram(for: b)
        renderer.removeCachedDiagrams()
        _ = try await renderer.diagram(for: a)
        _ = try await renderer.diagram(for: b)
        _ = try await renderer.diagram(for: a)
        #expect(rendered == [a, b, a, b])
    }

    @Test func memoryPressureCannotStrandAnActiveDiagramSubscriber() async throws {
        let gate = MermaidTestGate()
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: { { try await gate.render($0) } })
        let pending = Task { try await renderer.diagram(for: request("active")) }
        await gate.waitForStart()
        renderer.removeCachedDiagrams()
        gate.release()
        let diagram = try await pending.value
        #expect(diagram.svg == "active")
        #expect(gate.requests.count == 1)
    }

    @Test func failuresAreCachedAndExplicitRetryInvalidatesThem() async throws {
        var attempts = 0
        let renderer = MermaidRenderer(cacheLimit: 3, byteLimit: 4096, makeRender: {
            { _ in attempts += 1; throw MermaidFailure(message: "Invalid syntax") }
        })
        let input = request("invalid")
        for _ in 0..<2 {
            await #expect(throws: MermaidFailure.self) { try await renderer.diagram(for: input) }
        }
        #expect(attempts == 1)
        renderer.invalidate(input)
        await #expect(throws: MermaidFailure.self) { try await renderer.diagram(for: input) }
        #expect(attempts == 2)
    }
}

@MainActor
private final class MermaidTestGate {
    var requests: [MermaidRequest] = []
    private var completion: CheckedContinuation<Void, Never>?
    private let starts = AsyncStream<Void>.makeStream()
    private var iterator: AsyncStream<Void>.Iterator?
    private var completesImmediately = false

    func render(_ request: MermaidRequest) async throws -> MermaidDiagram {
        requests.append(request)
        if completesImmediately { return Self.value(request.source) }
        await withCheckedContinuation { continuation in
            completion = continuation
            starts.continuation.yield(())
        }
        return Self.value(request.source)
    }

    func waitForStart() async {
        var iterator = self.iterator ?? starts.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: #isolation)
        self.iterator = iterator
    }

    func release() { completion?.resume(); completion = nil }

    func releaseAll() { completesImmediately = true; release() }

    static func value(_ source: String) -> MermaidDiagram {
        MermaidDiagram(svg: source, preview: Data([1]), size: CGSize(width: 100, height: 100),
                       title: "Example", summary: "", background: "#ffffff")
    }
}
