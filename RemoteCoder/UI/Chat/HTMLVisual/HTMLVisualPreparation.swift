import Foundation
import Observation
import OSLog

struct HTMLVisualLayoutContext: Equatable {
    var width: Int?
    var theme: HTMLVisualTheme?
    var displayScale: Double?
    var inlineHeightLimit = HTMLVisualInlineHeight.limit(interfaceScale: 1)

    var isComplete: Bool { width != nil && theme != nil && displayScale != nil }

    var preparationContext: HTMLVisualPreparationContext? {
        guard isComplete, let width, let theme else { return nil }
        return HTMLVisualPreparationContext(width: width, theme: theme)
    }

    func key(for reference: HTMLVisualReference) -> HTMLVisualLayoutKey? {
        guard let width, let theme else { return nil }
        return HTMLVisualLayoutKey(digest: reference.digest, width: width, theme: theme)
    }
}

@Observable
@MainActor
final class HTMLVisualPreparationSurface {
    var instance: HTMLVisualInstance?
    private(set) var host: UUID?

    func claim(_ id: UUID) -> Bool {
        if host == nil { host = id }
        return host == id
    }

    func release(_ id: UUID) {
        if host == id { host = nil }
    }
}

@MainActor
final class HTMLVisualPreparation {
    private enum Need { case pixels, geometry }

    private struct Request {
        let reference: HTMLVisualReference
        let documents: HTMLVisualDocumentStore
        let need: Need

        func covers(_ other: Request) -> Bool {
            other.reference.digest == reference.digest && (need == .pixels || other.need == .geometry)
        }
    }

    private enum Priority { case demanded, speculative, background }

    private struct Job {
        let request: Request
        let priority: Priority
    }

    private struct Waiter {
        let id: UUID
        var pending: [Request]
        let continuation: AsyncStream<Void>.Continuation
    }

    let surface = HTMLVisualPreparationSurface()
    private(set) var layoutContext = HTMLVisualLayoutContext()
    var onBackgroundPreparationReady: (@MainActor () -> Void)?
    private let renderer: HTMLVisualRenderer
    private var active = false
    private var conservesEnergy = false
    private var waiters: [Waiter] = []
    private var background: [Waiter] = []
    private var interacting = false
    private var nearDemand: (references: [HTMLVisualReference], documents: HTMLVisualDocumentStore)?
    private var near: [Request] = []
    private var nearPins: [HTMLVisualLayoutKey] = []
    private var speculative: [Request] = []
    private var currentJob: Job?
    private var lane: Task<Void, Never>?
    private var unpreparable: [HTMLVisualLayoutKey] = []
    private static let maximumRequests = 16
    private static let maximumUnpreparable = 64
    private static let pinnedPixels = HTMLVisualRasterBudget.maximumPixels - HTMLVisualRasterBudget.maximumImagePixels
    private static let pageTimeout = Duration.seconds(4)
    #if os(iOS)
    private static let preparesInBackground = true
    #else
    private static let preparesInBackground = false
    #endif
    private static let logger = AppLogger(category: "HTMLVisual")

    init(renderer: HTMLVisualRenderer) {
        self.renderer = renderer
    }

    isolated deinit {
        lane?.cancel()
        renderer.unpinRasters(nearPins)
    }

    func updateLayoutContext(_ change: (inout HTMLVisualLayoutContext) -> Void) {
        let previous = backgroundPreparationContext
        var context = layoutContext
        change(&context)
        guard layoutContext != context else { return }
        layoutContext = context
        finish(&background)
        #if DEBUG
        Self.logger.notice("html visual context width=\(context.width ?? -1) theme=\(context.theme != nil) scale=\(context.displayScale ?? -1)")
        #endif
        planNear()
        stateChanged()
        notifyBackgroundPreparationReady(previous: previous)
    }

    func setActive(_ active: Bool, conservesEnergy: Bool) {
        guard self.active != active || self.conservesEnergy != conservesEnergy else { return }
        let previous = backgroundPreparationContext
        self.active = active
        self.conservesEnergy = conservesEnergy
        if !active { interacting = false }
        #if DEBUG
        Self.logger.notice("html visual preparation active=\(active) conserving=\(conservesEnergy) uptime=\(ProcessInfo.processInfo.systemUptime)")
        #endif
        stateChanged()
        notifyBackgroundPreparationReady(previous: previous)
    }

    var backgroundPreparationContext: HTMLVisualPreparationContext? {
        guard Self.preparesInBackground, active, surface.host != nil, !conservesEnergy else { return nil }
        return layoutContext.preparationContext
    }

    private func notifyBackgroundPreparationReady(previous: HTMLVisualPreparationContext?) {
        if let context = backgroundPreparationContext, context != previous { onBackgroundPreparationReady?() }
    }

    func cancelDemand() {
        nearDemand = nil
        planNear()
        speculative.removeAll()
        interacting = false
        lane?.cancel()
        finish(&waiters, clearing: true)
        finish(&background)
    }

    func setInteracting(_ interacting: Bool) {
        guard self.interacting != interacting else { return }
        self.interacting = interacting
        if interacting, currentJob?.priority == .background {
            #if DEBUG
            Self.logger.notice("html visual background yields to interaction")
            #endif
            lane?.cancel()
        }
        startLaneIfNeeded()
    }

    func prepareInBackground(_ references: [HTMLVisualReference],
                             documents: HTMLVisualDocumentStore) async -> HTMLVisualPreparationOutcome {
        guard Self.preparesInBackground else { return .unsupported }
        var attempted = Set<String>()
        while true {
            let remaining = references.filter { !attempted.contains($0.digest) && !isSatisfied($0, need: .geometry) }
            guard !remaining.isEmpty else { return backgroundOutcome(references) }
            guard canPrepare, !conservesEnergy, !Task.isCancelled else { return .interrupted }
            let pending = plan(remaining, documents: documents, wantsPixels: false)
            guard !pending.isEmpty else { return backgroundOutcome(references) }
            attempted.formUnion(pending.map(\.reference.digest))
            guard await waitInBackground(for: pending) else { return .interrupted }
        }
    }

    func isPresentable(_ reference: HTMLVisualReference) -> Bool {
        guard let key = layoutContext.key(for: reference), let scale = layoutContext.displayScale else { return false }
        return renderer.height(for: key) != nil && renderer.currentRaster(for: key, displayScale: scale) != nil
    }

    @discardableResult
    func awaitPresentable(_ references: [HTMLVisualReference], documents: HTMLVisualDocumentStore,
                          atMost deadline: Duration) async -> Bool {
        await wait(for: plan(references, documents: documents, wantsPixels: true), atMost: deadline)
    }

    @discardableResult
    func awaitMeasured(_ references: [HTMLVisualReference], documents: HTMLVisualDocumentStore,
                       atMost deadline: Duration) async -> Bool {
        await wait(for: plan(references, documents: documents, wantsPixels: false), atMost: deadline)
    }

    func warm(_ references: [HTMLVisualReference], documents: HTMLVisualDocumentStore) {
        guard canPrepare, !conservesEnergy else { return }
        let incoming = plan(references, documents: documents, wantsPixels: false).filter { !isSatisfied($0) }
        let digests = Set(incoming.map(\.reference.digest))
        speculative = Array((incoming + speculative.filter { !digests.contains($0.reference.digest) }).prefix(Self.maximumRequests))
        startLaneIfNeeded()
    }

    func updateNear(_ references: [HTMLVisualReference], documents: HTMLVisualDocumentStore) {
        nearDemand = (references, documents)
        planNear()
        startLaneIfNeeded()
    }

    private var canPrepare: Bool { active && layoutContext.isComplete }

    private func plan(_ references: [HTMLVisualReference], documents: HTMLVisualDocumentStore,
                      wantsPixels: Bool) -> [Request] {
        needs(references, wantsPixels: wantsPixels).map { Request(reference: $0.reference, documents: documents, need: $0.need) }
    }

    private func needs(_ references: [HTMLVisualReference], wantsPixels: Bool) -> [(reference: HTMLVisualReference, need: Need)] {
        guard let scale = layoutContext.displayScale else { return [] }
        var seen = Set<String>()
        var pixels = 0
        var fits = wantsPixels
        var needs: [(reference: HTMLVisualReference, need: Need)] = []
        for reference in references {
            guard needs.count < Self.maximumRequests else { break }
            guard let key = layoutContext.key(for: reference), !unpreparable.contains(key),
                  seen.insert(reference.digest).inserted else { continue }
            let expected = renderer.expectedRasterPixels(for: key, displayScale: scale)
            fits = fits && (pixels == 0 || pixels + expected <= Self.pinnedPixels)
            if fits { pixels += expected }
            needs.append((reference, fits ? .pixels : .geometry))
        }
        return needs
    }

    private func isSatisfied(_ request: Request) -> Bool {
        isSatisfied(request.reference, need: request.need)
    }

    private func isSatisfied(_ reference: HTMLVisualReference, need: Need) -> Bool {
        guard let key = layoutContext.key(for: reference) else { return false }
        switch need {
        case .pixels: return isPresentable(reference)
        case .geometry: return renderer.height(for: key) != nil && renderer.hasStoredSnapshot(for: key)
        }
    }

    private func planNear() {
        let planned = nearDemand.map { plan($0.references, documents: $0.documents, wantsPixels: true) }?
            .filter { $0.need == .pixels } ?? []
        near = planned.filter { !isSatisfied($0) }
        let pins = planned.compactMap { layoutContext.key(for: $0.reference) }
        renderer.pinRasters(pins)
        renderer.unpinRasters(nearPins)
        nearPins = pins
        yieldSpeculativeJob(to: near)
    }

    private func wait(for planned: [Request], atMost deadline: Duration) async -> Bool {
        let pending = planned.filter { !isSatisfied($0) }
        guard canPrepare, !pending.isEmpty else { return false }
        let pinned = planned.filter { $0.need == .pixels }.compactMap { layoutContext.key(for: $0.reference) }
        renderer.pinRasters(pinned)
        defer { renderer.unpinRasters(pinned) }
        let id = UUID()
        let (settled, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(Waiter(id: id, pending: pending, continuation: continuation))
        defer {
            waiters.removeAll { $0.id == id }
            continuation.finish()
        }
        yieldSpeculativeJob(to: pending)
        startLaneIfNeeded()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in settled {} }
            group.addTask { try? await Task.sleep(for: deadline) }
            await group.next()
            group.cancelAll()
        }
        return true
    }

    private func backgroundOutcome(_ references: [HTMLVisualReference]) -> HTMLVisualPreparationOutcome {
        let keys = Set(references.compactMap(layoutContext.key(for:)))
        let stored = keys.filter { renderer.height(for: $0) != nil && renderer.hasStoredSnapshot(for: $0) }
        let unpreparable = keys.subtracting(stored).filter(self.unpreparable.contains)
        let missing = keys.count - stored.count - unpreparable.count
        return missing == 0 ? .settled(stored: stored.count, unpreparable: unpreparable.count) : .incomplete(missing: missing)
    }

    private func waitInBackground(for pending: [Request]) async -> Bool {
        let id = UUID()
        let (settled, continuation) = AsyncStream<Void>.makeStream()
        background.append(Waiter(id: id, pending: pending, continuation: continuation))
        defer {
            background.removeAll { $0.id == id }
            continuation.finish()
        }
        startLaneIfNeeded()
        for await _ in settled {}
        return background.first { $0.id == id }?.pending.isEmpty == true
    }

    private func yieldSpeculativeJob(to demand: [Request]) {
        guard let currentJob, currentJob.priority != .demanded,
              !demand.isEmpty, !demand.contains(where: { $0.reference.digest == currentJob.request.reference.digest })
        else { return }
        lane?.cancel()
    }

    private func stateChanged() {
        if let currentJob, !canPrepare || (currentJob.priority != .demanded && conservesEnergy) { lane?.cancel() }
        if !canPrepare { finish(&waiters, clearing: true) }
        if !canPrepare || conservesEnergy { finish(&background) }
        startLaneIfNeeded()
    }

    private func finish(_ waiters: inout [Waiter], clearing: Bool = false) {
        for index in waiters.indices {
            if clearing { waiters[index].pending.removeAll() }
            waiters[index].continuation.finish()
        }
    }

    private func settle(_ attempt: Request, failed: Bool) {
        let settles = { (request: Request) in
            request.reference.digest == attempt.reference.digest && (failed || attempt.covers(request))
        }
        for index in waiters.indices {
            waiters[index].pending.removeAll(where: settles)
            if waiters[index].pending.isEmpty { waiters[index].continuation.finish() }
        }
        for index in background.indices {
            background[index].pending.removeAll(where: settles)
            if background[index].pending.isEmpty { background[index].continuation.finish() }
        }
        near.removeAll(where: settles)
        speculative.removeAll { $0.reference.digest == attempt.reference.digest }
    }

    private func nextJob() -> Job? {
        guard canPrepare else { return nil }
        if let request = waiters.lazy.compactMap({ $0.pending.first { $0.need == .pixels } }).first {
            return Job(request: request, priority: .demanded)
        }
        if let request = near.first { return Job(request: request, priority: .demanded) }
        if let request = waiters.lazy.compactMap(\.pending.first).first { return Job(request: request, priority: .demanded) }
        guard !conservesEnergy else { return nil }
        if let request = speculative.first { return Job(request: request, priority: .speculative) }
        if !interacting, let request = background.lazy.compactMap(\.pending.first).first {
            return Job(request: request, priority: .background)
        }
        return nil
    }

    private func startLaneIfNeeded() {
        guard lane == nil, nextJob() != nil else { return }
        lane = Task {
            await drain()
            lane = nil
            startLaneIfNeeded()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let job = nextJob(),
              let key = layoutContext.key(for: job.request.reference), let scale = layoutContext.displayScale {
            currentJob = job
            let failed = await process(job.request, key: key, displayScale: scale)
            currentJob = nil
            guard !Task.isCancelled else { return }
            guard layoutContext.key(for: job.request.reference) == key, layoutContext.displayScale == scale else { continue }
            if failed, !unpreparable.contains(key) {
                unpreparable.append(key)
                if unpreparable.count > Self.maximumUnpreparable { unpreparable.removeFirst() }
            }
            settle(job.request, failed: failed)
        }
    }

    private func process(_ request: Request, key: HTMLVisualLayoutKey, displayScale: Double) async -> Bool {
        let stored = renderer.height(for: key) != nil && renderer.hasStoredSnapshot(for: key)
        if request.need == .pixels ? isPresentable(request.reference) : stored { return false }
        if !stored {
            if await render(request, key: key) { return true }
            guard !Task.isCancelled else { return false }
        }
        if request.need == .pixels {
            _ = await renderer.preparedRaster(for: key, displayScale: displayScale)
        }
        return false
    }

    private func render(_ request: Request, key: HTMLVisualLayoutKey) async -> Bool {
        let instance = HTMLVisualInstance(surface: .inline)
        instance.preparing = true
        instance.inlineHeightLimit = layoutContext.inlineHeightLimit
        let (stored, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        instance.onSnapshotStored = { continuation.yield() }
        surface.instance = instance
        let started = ContinuousClock.now
        let run = Task {
            await renderer.run(instance, reference: request.reference, key: key,
                document: { try await request.documents.document(request.reference) }, open: { _ in }, onPinChange: { _ in })
            continuation.finish()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stored { return } }
            group.addTask { try? await Task.sleep(for: Self.pageTimeout) }
            await group.next()
            group.cancelAll()
        }
        run.cancel()
        await run.value
        if surface.instance === instance { surface.instance = nil }
        #if DEBUG
        Self.logger.notice("html visual prepared digest=\(key.digest.prefix(8)) width=\(key.width) stored=\(self.renderer.hasStoredSnapshot(for: key)) height=\(self.renderer.height(for: key) ?? -1) priority=\(self.currentJob.map { String(describing: $0.priority) } ?? "none") cancelled=\(Task.isCancelled) ms=\(Int((ContinuousClock.now - started) / .milliseconds(1))) uptime=\(ProcessInfo.processInfo.systemUptime)")
        #endif
        return instance.failure != nil
    }
}
