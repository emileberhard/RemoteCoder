import Foundation
import Observation
import OSLog
import SwiftUI
import WebKit

struct HTMLVisualCapturedImage {
    static let maximumBytes = (24 << 20) / HTMLVisualPageAdmission.maximumLivePages
    let id = UUID()
    let data: Data
    let key: HTMLVisualLayoutKey
    let revision: Int

    init?(data: Data, key: HTMLVisualLayoutKey, revision: Int) {
        guard data.count <= Self.maximumBytes else { return nil }
        self.data = data
        self.key = key
        self.revision = revision
    }
}

@Observable
@MainActor
final class HTMLVisualSnapshot {
    var image: Data?
    var height: Double?
    var revision = 0
    @ObservationIgnored var byteCount = 0
}

@Observable
@MainActor
final class HTMLVisualInstance: Identifiable {
    enum Surface: String { case inline, expanded }
    struct AdmissionDemand: Equatable {
        let active: Bool
        let rowVisible: Bool
        let occurrenceVisible: Bool?
    }
    let surface: Surface
    var page: WebPage?
    @ObservationIgnored var userContentController: WKUserContentController?
    var measured = false
    var height: Double = 180
    enum Status: Equatable { case idle, waiting, loading, live, suspended, unavailable(String) }
    var status = Status.idle
    var failure: String? {
        guard case .unavailable(let message) = status else { return nil }
        return message
    }
    var waiting: Bool { status == .waiting }
    var interacting = false
    var userSelected = false
    var isResizing = false
    @ObservationIgnored var inlineHeightLimit = HTMLVisualInlineHeight.limit(interfaceScale: 1)
    var snapshot: HTMLVisualSnapshot?
    var capturedImage: HTMLVisualCapturedImage?
    @ObservationIgnored var key: HTMLVisualLayoutKey?
    @ObservationIgnored var pendingHeight: Double?
    @ObservationIgnored var requestID: UUID?
    @ObservationIgnored var operation: Task<Void, Never>?
    @ObservationIgnored var operationGeneration = 0
    @ObservationIgnored var capture: Task<Void, Never>?
    @ObservationIgnored var update: Task<Void, Never>?
    @ObservationIgnored var revision = 0
    @ObservationIgnored var needsSnapshot = false
    @ObservationIgnored var preparing = false
    @ObservationIgnored var onCaptureFinished: () -> Void = {}
    @ObservationIgnored var captureAllowed = false
    @ObservationIgnored var onPinChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var admissionDemand: AdmissionDemand?
    @ObservationIgnored var activity: HTMLVisualPageActivity?

    var rowVisible: Bool { admissionDemand?.rowVisible == true }
    var occurrenceVisible: Bool? { admissionDemand?.occurrenceVisible }

    var pinned: Bool { interacting || surface == .expanded }

    init(surface: Surface) {
        self.surface = surface
    }

    func retirePage() {
        userContentController?.removeScriptMessageHandler(forName: "rcVisual", contentWorld: .defaultClient)
        userContentController = nil
        page?.stopLoading()
        page = nil
    }
}

@MainActor
final class HTMLVisualPageActivity {
    enum ReleaseReason: String {
        case ended, cancelled, superseded, selectedEviction, preparationPreempted, energyConservation, failed, webContentTerminated
    }

    let started = ContinuousClock.now
    let kind: HTMLVisualPageAdmission.Kind
    var releaseReason = ReleaseReason.ended
    var layoutEvents = 0
    var settledEvents = 0
    var capturesStarted = 0
    var capturesCompleted = 0
    var captureDuration = Duration.zero

    init(kind: HTMLVisualPageAdmission.Kind) {
        self.kind = kind
    }
}

final class HTMLVisualPreparedRaster: Sendable {
    let image: DecodedImage
    let raster: HTMLVisualRaster
    let key: HTMLVisualLayoutKey
    let revision: Int

    init(image: DecodedImage, raster: HTMLVisualRaster, key: HTMLVisualLayoutKey, revision: Int) {
        self.image = image
        self.raster = raster
        self.key = key
        self.revision = revision
    }

    func sharpens(_ base: HTMLVisualPreparedRaster) -> Bool {
        key == base.key && revision == base.revision && raster.reservation.scale > base.raster.reservation.scale
    }
}

@MainActor
final class HTMLVisualRenderer {
    private(set) var isReady = false
    private let webContent: HTMLVisualWebContent
    private let rasterBudget = HTMLVisualRasterBudget(capacity: HTMLVisualRasterBudget.maximumPixels,
        imagePixels: HTMLVisualRasterBudget.maximumImagePixels)
    private static let sharpPixels = 16 << 20
    private let sharpBudget = HTMLVisualRasterBudget(capacity: sharpPixels, imagePixels: sharpPixels)
    private struct SharedSharpRaster { weak var raster: HTMLVisualPreparedRaster? }
    private var sharpRasters: [RasterKey: SharedSharpRaster] = [:]
    private var sharpWork: [RasterKey: Task<HTMLVisualRaster?, Never>] = [:]
    private static let logger = AppLogger(category: "HTMLVisual")
    private var admission = HTMLVisualPageAdmission()
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private struct PageWork {
        let task: Task<Void, Never>
        let activity: HTMLVisualPageActivity
    }
    private var work: [UUID: PageWork] = [:]
    private var snapshots: [HTMLVisualLayoutKey: HTMLVisualSnapshot] = [:]
    private var snapshotOrder: [HTMLVisualLayoutKey] = []
    private var heights: [HTMLVisualLayoutKey: Double] = [:]
    private var heightOrder: [HTMLVisualLayoutKey] = []
    private struct RasterKey: Hashable { let key: HTMLVisualLayoutKey; let revision: Int; let scale: Double }
    private struct RasterWork {
        let task: Task<HTMLVisualRaster?, Never>
        var consumers: Set<UUID>
    }
    private var rasters: [RasterKey: HTMLVisualPreparedRaster] = [:]
    private var rasterOrder: [RasterKey] = []
    private var rasterWork: [RasterKey: RasterWork] = [:]
    private var rasterPins: [HTMLVisualLayoutKey: Int] = [:]
    private var superseded: Set<RasterKey> = []
    private var persistedImages = HTMLVisualPresentationCoverage()
    private var snapshotRevisions = 0
    private static let retainedRasterPixels = HTMLVisualRasterBudget.maximumPixels / 2
    private let cache: HTMLVisualPresentationCache
    private var loadTask: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var pendingHeights: [HTMLVisualLayoutKey: Double] = [:]

    init(cache: HTMLVisualPresentationCache, webContent: HTMLVisualWebContent) {
        self.cache = cache
        self.webContent = webContent
    }

    isolated deinit {
        loadTask?.cancel()
        persistence?.cancel()
        for work in work.values { work.task.cancel() }
        for raster in rasterWork.values { raster.task.cancel() }
        for task in sharpWork.values { task.cancel() }
    }

    func load() async {
        startLoading()
        await loadTask?.value
    }

    func startLoading() {
        if isReady { return }
        if loadTask == nil {
            loadTask = Task {
                do {
                    let snapshot = try await cache.load()
                    try Task.checkCancellation()
                    for (key, entry) in snapshot.entries {
                        heights[key] = entry.height
                        heightOrder.append(key)
                        snapshots[key]?.height = entry.height
                    }
                    persistedImages.apply(snapshot)
                } catch is CancellationError { return }
                catch { Self.logger.error("html visual cache load failed reason=\(error.localizedDescription)") }
                isReady = true
            }
        }
    }

    func restoreImage(for key: HTMLVisualLayoutKey) async -> HTMLVisualSnapshot {
        if let cached = snapshots[key], cached.image != nil {
            do { try await cache.touch(key) }
            catch is CancellationError {}
            catch { Self.logger.error("html visual cache access failed reason=\(error.localizedDescription)") }
            return cached
        }
        do {
            guard let data = try await cache.image(for: key) else {
                persistedImages.apply(try await cache.load())
                return snapshot(for: key)
            }
            try Task.checkCancellation()
            let cached = snapshot(for: key)
            guard cached.image == nil else { return cached }
            cached.image = data
            cached.byteCount = data.count
            cached.revision = nextSnapshotRevision()
            trimSnapshots()
        } catch is CancellationError { }
        catch { Self.logger.error("html visual snapshot restore failed reason=\(error.localizedDescription)") }
        return snapshot(for: key)
    }

    func hasStoredSnapshot(for key: HTMLVisualLayoutKey) -> Bool {
        snapshots[key]?.image != nil || persistedImages.contains(key)
    }

    func presentableRaster(for key: HTMLVisualLayoutKey, displayScale: Double) -> HTMLVisualPreparedRaster? {
        rasterOrder.last { $0.key == key && $0.scale == displayScale }.flatMap(retainedRaster)
    }

    func presentableRaster(for capture: HTMLVisualCapturedImage, displayScale: Double) -> HTMLVisualPreparedRaster? {
        retainedRaster(RasterKey(key: capture.key, revision: capture.revision, scale: displayScale))
    }

    func pinRasters(_ keys: [HTMLVisualLayoutKey]) {
        for key in keys { rasterPins[key, default: 0] += 1 }
    }

    func unpinRasters(_ keys: [HTMLVisualLayoutKey]) {
        for key in keys {
            guard let count = rasterPins[key] else { continue }
            rasterPins[key] = count > 1 ? count - 1 : nil
        }
    }

    func currentRaster(for key: HTMLVisualLayoutKey, displayScale: Double) -> HTMLVisualPreparedRaster? {
        rasterOrder.last { $0.key == key && $0.scale == displayScale && !superseded.contains($0) }.flatMap(retainedRaster)
    }

    func preparedRaster(for key: HTMLVisualLayoutKey, displayScale: Double) async -> HTMLVisualPreparedRaster? {
        if let current = currentRaster(for: key, displayScale: displayScale) { return current }
        let snapshot = await restoreImage(for: key)
        guard let data = snapshot.image else { return nil }
        return await preparedRaster(data, as: RasterKey(key: key, revision: snapshot.revision, scale: displayScale))
    }

    func preparedRaster(for capture: HTMLVisualCapturedImage, displayScale: Double) async -> HTMLVisualPreparedRaster? {
        await preparedRaster(capture.data, as: RasterKey(key: capture.key, revision: capture.revision, scale: displayScale))
    }

    private func retainedRaster(_ rasterKey: RasterKey) -> HTMLVisualPreparedRaster? {
        guard let prepared = rasters[rasterKey] else { return nil }
        rasterOrder.removeAll { $0 == rasterKey }
        rasterOrder.append(rasterKey)
        return prepared
    }

    private func preparedRaster(_ data: Data, as rasterKey: RasterKey) async -> HTMLVisualPreparedRaster? {
        if let prepared = retainedRaster(rasterKey) { return prepared }
        guard !Task.isCancelled else { return nil }
        let consumer = UUID()
        if rasterWork[rasterKey] == nil {
            makeRoom(for: rasterKey)
            #if DEBUG
            let retained = rasterOrder.map { "\($0.key.digest.prefix(4))@\($0.revision)\(rasterPins[$0.key] != nil ? "p" : "")\(isHeld($0) ? "h" : "")" }
            let outside = rasterBudget.reservedPixels - rasterOrder.reduce(0) { $0 + pixelCount(rasters[$1]) }
            Self.logger.notice("html visual decode digest=\(rasterKey.key.digest.prefix(8)) revision=\(rasterKey.revision) pinned=\(self.rasterPins[rasterKey.key] != nil) available=\(self.rasterBudget.availablePixels) retained=\(retained.joined(separator: ",")) outside=\(outside)")
            #endif
        }
        let task = rasterWork[rasterKey]?.task ?? Task { await prepareImage(data, displayScale: rasterKey.scale) }
        rasterWork[rasterKey, default: RasterWork(task: task, consumers: [])].consumers.insert(consumer)
        let raster = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.releaseRasterWork(rasterKey, consumer: consumer, finished: false) }
        }
        releaseRasterWork(rasterKey, consumer: consumer, finished: true)
        guard let raster, !Task.isCancelled else { return nil }
        if let prepared = rasters[rasterKey] { return prepared }
        let prepared = HTMLVisualPreparedRaster(image: DecodedImage.make(cgImage: raster.image), raster: raster,
            key: rasterKey.key, revision: rasterKey.revision)
        retain(prepared, as: rasterKey)
        return prepared
    }

    func sharpRaster(for base: HTMLVisualPreparedRaster, capture: HTMLVisualCapturedImage?,
                     displayScale: Double) async -> HTMLVisualPreparedRaster? {
        let reservation = base.raster.reservation
        guard reservation.scale < displayScale else { return nil }
        let rasterKey = RasterKey(key: base.key, revision: base.revision, scale: displayScale)
        if let shared = sharpRasters[rasterKey]?.raster { return shared }
        let pdf: Data
        if let capture, capture.key == base.key, capture.revision == base.revision {
            pdf = capture.data
        } else {
            let stored = await restoreImage(for: base.key)
            guard stored.revision == base.revision, let image = stored.image else { return nil }
            pdf = image
        }
        guard !Task.isCancelled else { return nil }
        let task = sharpWork[rasterKey] ?? startSharpDecode(pdf, as: rasterKey, above: reservation.scale)
        let raster = await task.value
        #if DEBUG
        Self.logger.notice("html visual sharp digest=\(base.key.digest.prefix(8)) revision=\(base.revision) base=\(reservation.scale) granted=\(raster?.reservation.scale ?? 0) cancelled=\(Task.isCancelled)")
        #endif
        guard let raster, !Task.isCancelled else { return nil }
        if let shared = sharpRasters[rasterKey]?.raster { return shared }
        let prepared = HTMLVisualPreparedRaster(image: DecodedImage.make(cgImage: raster.image), raster: raster,
            key: base.key, revision: base.revision)
        sharpRasters = sharpRasters.filter { $0.value.raster != nil }
        sharpRasters[rasterKey] = SharedSharpRaster(raster: prepared)
        return prepared
    }

    func expectedRasterPixels(for key: HTMLVisualLayoutKey, displayScale: Double) -> Int {
        guard let height = heights[key] else { return HTMLVisualRasterBudget.maximumImagePixels }
        return Int(min(Double(HTMLVisualRasterBudget.maximumImagePixels), Double(key.width) * height * displayScale * displayScale))
    }

    private func makeRoom(for rasterKey: RasterKey) {
        let wanted = expectedRasterPixels(for: rasterKey.key, displayScale: rasterKey.scale)
        while rasterBudget.availablePixels < wanted,
              let victim = rasterOrder.first(where: { $0.key != rasterKey.key && isEvictable($0) }) {
            evictRaster(victim)
        }
    }

    private func isEvictable(_ rasterKey: RasterKey) -> Bool {
        rasterPins[rasterKey.key] == nil && rasters[rasterKey] != nil && !isHeld(rasterKey)
    }

    private func isHeld(_ rasterKey: RasterKey) -> Bool {
        guard rasters[rasterKey] != nil else { return false }
        return !isKnownUniquelyReferenced(&rasters[rasterKey])
    }

    private func startSharpDecode(_ pdf: Data, as rasterKey: RasterKey, above scale: Double)
        -> Task<HTMLVisualRaster?, Never> {
        let task = Task { [sharpBudget] in
            await sharpBudget.rasterize(pdf, displayScale: rasterKey.scale, minimumScale: scale.nextUp)
        }
        sharpWork[rasterKey] = task
        Task { [weak self] in
            _ = await task.value
            if self?.sharpWork[rasterKey] == task { self?.sharpWork[rasterKey] = nil }
        }
        return task
    }

    private func releaseRasterWork(_ rasterKey: RasterKey, consumer: UUID, finished: Bool) {
        guard var work = rasterWork[rasterKey], work.consumers.remove(consumer) != nil else { return }
        guard work.consumers.isEmpty else {
            rasterWork[rasterKey] = work
            return
        }
        rasterWork.removeValue(forKey: rasterKey)
        if !finished { work.task.cancel() }
    }

    private func retain(_ prepared: HTMLVisualPreparedRaster, as rasterKey: RasterKey) {
        guard !rasterOrder.contains(where: { $0.key == rasterKey.key && $0.revision > rasterKey.revision }) else { return }
        for stale in rasterOrder where stale.key == rasterKey.key { evictRaster(stale) }
        rasters[rasterKey] = prepared
        rasterOrder.append(rasterKey)
        if let stored = snapshots[rasterKey.key], stored.image != nil, stored.revision > rasterKey.revision {
            superseded.insert(rasterKey)
        }
        trimRasters()
    }

    func releaseReusableCaches() {
        for key in rasterOrder.filter(isEvictable) { evictRaster(key) }
    }

    private func trimRasters() {
        var evictable = rasterOrder.filter(isEvictable)
        var pixels = evictable.reduce(0) { $0 + pixelCount(rasters[$1]) }
        while pixels > Self.retainedRasterPixels, let oldest = evictable.first {
            evictable.removeFirst()
            pixels -= pixelCount(rasters[oldest])
            evictRaster(oldest)
        }
    }

    private func pixelCount(_ prepared: HTMLVisualPreparedRaster?) -> Int {
        prepared.map { $0.raster.reservation.width * $0.raster.reservation.height } ?? 0
    }

    private func evictRaster(_ rasterKey: RasterKey) {
        rasterOrder.removeAll { $0 == rasterKey }
        rasters.removeValue(forKey: rasterKey)
        superseded.remove(rasterKey)
    }

    func flush() async throws {
        await persistence?.value
        try await cache.flush()
    }

    func snapshot(for key: HTMLVisualLayoutKey) -> HTMLVisualSnapshot {
        if let snapshot = snapshots[key] { return snapshot }
        let snapshot = HTMLVisualSnapshot()
        snapshot.height = heights[key]
        snapshots[key] = snapshot
        snapshotOrder.append(key)
        trimSnapshots()
        return snapshot
    }

    func height(for key: HTMLVisualLayoutKey) -> Double? { heights[key] }

    private func nextSnapshotRevision() -> Int {
        snapshotRevisions += 1
        return snapshotRevisions
    }

    private nonisolated func prepareImage(_ pdf: Data, displayScale: Double) async -> HTMLVisualRaster? {
        let raster = await rasterBudget.rasterize(pdf, displayScale: displayScale, minimumScale: min(1, displayScale))
        #if DEBUG
        AppLogger(category: "HTMLVisual").notice("html visual raster granted=\(raster != nil) reserved=\(self.rasterBudget.reservedPixels)")
        #endif
        return raster
    }

    func run(_ instance: HTMLVisualInstance, reference: HTMLVisualReference, key: HTMLVisualLayoutKey,
             document: @escaping @MainActor () async throws -> String,
             open: @escaping @MainActor (HTMLVisualOpenRequest) -> Void,
             onPinChange: @escaping @MainActor (Bool) -> Void) async {
        instance.operationGeneration += 1
        let generation = instance.operationGeneration
        let previous = instance.operation
        if previous != nil { instance.activity?.releaseReason = .superseded }
        previous?.cancel()
        await previous?.value
        guard !Task.isCancelled, instance.operationGeneration == generation else { return }
        let operation = Task {
            await performRun(instance, reference: reference, key: key, document: document,
                             open: open, onPinChange: onPinChange)
        }
        instance.operation = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        if instance.operationGeneration == generation { instance.operation = nil }
    }

    private func performRun(_ instance: HTMLVisualInstance, reference: HTMLVisualReference, key: HTMLVisualLayoutKey,
                            document: @escaping @MainActor () async throws -> String,
                            open: @escaping @MainActor (HTMLVisualOpenRequest) -> Void,
                            onPinChange: @escaping @MainActor (Bool) -> Void) async {
        let key = instance.key ?? key
        guard key.digest == reference.digest else { return }
        instance.onPinChange = onPinChange
        let id = UUID()
        instance.requestID = id
        instance.pendingHeight = nil
        instance.key = key
        instance.snapshot = snapshot(for: key)
        instance.height = instance.snapshot?.height ?? 180
        instance.status = .waiting
        let kind: HTMLVisualPageAdmission.Kind = instance.preparing ? .preparation
            : instance.userSelected || instance.surface == .expanded ? .selected : .automatic
        do {
            try await acquire(id, kind: kind)
            try Task.checkCancellation()
            pin(instance)
        } catch {
            release(id)
            if instance.requestID == id {
                instance.requestID = nil
                instance.status = error is CancellationError || instance.preparing
                    ? .suspended : .unavailable(error.localizedDescription)
                instance.onPinChange = { _ in }
            }
            return
        }
        let activity = HTMLVisualPageActivity(kind: kind)
        instance.activity = activity
        let task = Task {
            await render(instance, requestID: id, reference: reference, document: document, open: open)
        }
        work[id] = PageWork(task: task, activity: activity)
        instance.status = .loading
        Self.logger.notice("html visual admitted id=\(id.uuidString.prefix(8)) digest=\(key.digest.prefix(12)) surface=\(instance.surface.rawValue) reason=\(String(describing: kind)) rowVisible=\(instance.rowVisible) occurrenceVisible=\(instance.occurrenceVisible.map(String.init) ?? "unknown") pinned=\(instance.pinned) live=\(self.admission.live.count) waiting=\(self.admission.waiting.count)")
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        work.removeValue(forKey: id)
        if Task.isCancelled, activity.releaseReason == .ended { activity.releaseReason = .cancelled }
        let pinned = instance.pinned
        #if DEBUG
        Self.logger.notice("html visual teardown status=\(String(describing: instance.status)) stored=\(self.snapshots[key]?.image != nil) digest=\(key.digest.prefix(8))")
        #endif
        if instance.requestID == id {
            instance.retirePage()
            instance.capturedImage = nil
            let capture = instance.capture
            let update = instance.update
            capture?.cancel()
            update?.cancel()
            await capture?.value
            await update?.value
            instance.requestID = nil
            instance.measured = false
            instance.interacting = false
            instance.capture = nil
            instance.update = nil
            instance.needsSnapshot = false
            if instance.failure == nil { instance.status = .suspended }
            instance.onPinChange(instance.pinned)
            instance.onPinChange = { _ in }
            instance.activity = nil
        }
        release(id)
        let lifetime = activity.started.duration(to: .now).milliseconds
        Self.logger.notice("html visual released id=\(id.uuidString.prefix(8)) digest=\(key.digest.prefix(12)) surface=\(instance.surface.rawValue) admission=\(String(describing: activity.kind)) reason=\(activity.releaseReason.rawValue) rowVisible=\(instance.rowVisible) occurrenceVisible=\(instance.occurrenceVisible.map(String.init) ?? "unknown") pinned=\(pinned) lifetimeMs=\(lifetime) layouts=\(activity.layoutEvents) settled=\(activity.settledEvents) capturesStarted=\(activity.capturesStarted) capturesCompleted=\(activity.capturesCompleted) captureMs=\(activity.captureDuration.milliseconds) live=\(self.admission.live.count) waiting=\(self.admission.waiting.count)")
    }

    func update(_ instance: HTMLVisualInstance, key: HTMLVisualLayoutKey) {
        guard instance.key != key else { return }
        instance.key = key
        instance.capturedImage = nil
        instance.snapshot = snapshot(for: key)
        refresh(instance)
    }

    func beginResize(_ instance: HTMLVisualInstance) {
        if !instance.isResizing { instance.isResizing = true }
    }

    func finishResize(_ instance: HTMLVisualInstance, key: HTMLVisualLayoutKey) {
        instance.isResizing = false
        if instance.key == key { refresh(instance) }
        else { update(instance, key: key) }
    }

    private func refresh(_ instance: HTMLVisualInstance) {
        instance.revision += 1
        guard instance.status == .live, instance.update == nil, let page = instance.page else { return }
        instance.update = Task {
            defer { instance.update = nil }
            do {
                while let next = instance.key, instance.page === page {
                    let revision = instance.revision
                    try await HTMLVisualWebContent.apply(page, theme: next.theme, scrolling: instance.surface == .expanded)
                    try Task.checkCancellation()
                    guard instance.page === page else { return }
                    if instance.revision == revision {
                        capture(instance)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                guard instance.page === page else { return }
                instance.status = .unavailable(error.localizedDescription)
                if let id = instance.requestID { cancel(id, reason: .failed) }
            }
        }
    }

    func promote(_ instance: HTMLVisualInstance) {
        instance.userSelected = true
        guard let id = instance.requestID, instance.waiting else { return }
        admission.prioritize(id)
        if let next = admission.admitWaiting() { waiters.removeValue(forKey: next)?.resume(); return }
        if let victim = admission.evictionCandidate(excluding: id) { cancel(victim, reason: .selectedEviction) }
    }

    private func acquire(_ id: UUID, kind: HTMLVisualPageAdmission.Kind) async throws {
        try Task.checkCancellation()
        if try admission.request(id, kind: kind) { return }
        if kind == .selected {
            admission.prioritize(id)
            if let victim = admission.evictionCandidate(excluding: id) { cancel(victim, reason: .selectedEviction) }
        } else if let victim = admission.preparationBlocking(id) {
            cancel(victim, reason: .preparationPreempted)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                self.release(id)
            }
        }
    }

    private func cancel(_ id: UUID, reason: HTMLVisualPageActivity.ReleaseReason) {
        guard let work = work[id] else { return }
        work.activity.releaseReason = reason
        work.task.cancel()
    }

    private func release(_ id: UUID) {
        if let next = admission.remove(id) { waiters.removeValue(forKey: next)?.resume() }
        if admission.live.isEmpty {
            Task { [weak self] in
                guard let self, admission.live.isEmpty else { return }
                await webContent.discardStorage()
            }
        }
    }

    private func render(_ instance: HTMLVisualInstance, requestID: UUID, reference: HTMLVisualReference,
                        document: @escaping @MainActor () async throws -> String,
                        open: @escaping @MainActor (HTMLVisualOpenRequest) -> Void) async {
        do {
            let page = try await prepare(instance, requestID: requestID, reference: reference, document: document, open: open)
            let events = page.navigations
            for try await _ in events { try Task.checkCancellation() }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            if let navigation = error as? WebPage.NavigationError,
               case .webContentProcessTerminated = navigation {
                instance.status = .suspended
                instance.activity?.releaseReason = .webContentTerminated
                Self.logger.notice("html visual web process terminated")
            } else {
                instance.status = .unavailable(error.localizedDescription)
                instance.activity?.releaseReason = .failed
                Self.logger.error("html visual failed reason=\(error.localizedDescription)")
            }
        }
    }

    private func prepare(_ instance: HTMLVisualInstance, requestID: UUID, reference: HTMLVisualReference,
                         document: @escaping @MainActor () async throws -> String,
                         open: @escaping @MainActor (HTMLVisualOpenRequest) -> Void) async throws -> WebPage {
        let signposter = AppPerformanceDiagnostics.pointsOfInterest
        let interval = signposter.beginInterval("HTMLVisualPageStartup", id: signposter.makeSignpostID())
        defer { signposter.endInterval("HTMLVisualPageStartup", interval) }
        let html = try await document()
        try Task.checkCancellation()
        guard let key = instance.key else { throw CancellationError() }
        let page = try await webContent.make(reference: reference, theme: key.theme,
            onEvent: { [weak self, weak instance] event in
                guard let self, let instance, instance.requestID == requestID, instance.page != nil else { return }
                switch event {
                case .layout(let height):
                    instance.activity?.layoutEvents += 1
                    instance.pendingHeight = height
                    if instance.status == .live { layout(instance, height: height) }
                case .interaction(let active):
                    instance.interacting = active
                    pin(instance)
                    if !active { capture(instance) }
                case .settled:
                    instance.activity?.settledEvents += 1
                    instance.capturedImage = nil
                    capture(instance)
                }
            }, open: { [weak instance] request in
                guard instance?.requestID == requestID, instance?.page != nil else { return }
                open(request)
            }, onRegistration: { instance.userContentController = $0 })
        try Task.checkCancellation()
        instance.page = page
        do { try await HTMLVisualWebContent.load(page, html: html, reference: reference) }
        catch {
            page.stopLoading()
            throw error
        }
        try Task.checkCancellation()
        while let latest = instance.key {
            try await HTMLVisualWebContent.apply(page, theme: latest.theme, scrolling: instance.surface == .expanded)
            try Task.checkCancellation()
            if instance.key == latest { break }
        }
        instance.status = .live
        if let height = instance.pendingHeight { layout(instance, height: height) }
        return page
    }

    private func layout(_ instance: HTMLVisualInstance, height: Double) {
        if instance.height != height { instance.capturedImage = nil }
        instance.height = height
        instance.measured = true
        if !instance.isResizing, instance.surface == .inline, let key = instance.key {
            heights[key] = height
            heightOrder.removeAll { $0 == key }
            heightOrder.append(key)
            if heightOrder.count > HTMLVisualPresentationCache.maximumHeights { heights.removeValue(forKey: heightOrder.removeFirst()) }
            instance.snapshot?.height = height
            persistHeight(height, for: key)
        }
        capture(instance)
    }

    private func pin(_ instance: HTMLVisualInstance) {
        if let id = instance.requestID {
            admission.pin(id, active: instance.pinned)
            if instance.pinned { admission.prioritize(id) }
        }
        instance.onPinChange(instance.pinned)
    }

    func setEnergyPolicy(_ policy: AppEnergyPolicy) {
        for victim in admission.conserveEnergy(policy.conservesEnergy) { cancel(victim, reason: .energyConservation) }
        while let next = admission.admitWaiting() { waiters.removeValue(forKey: next)?.resume() }
    }

    private func capture(_ instance: HTMLVisualInstance) {
        instance.needsSnapshot = true
        guard instance.captureAllowed || instance.preparing, instance.capture == nil, instance.measured,
              let page = instance.page else { return }
        instance.capture = Task {
            defer {
                instance.capture = nil
                if instance.needsSnapshot, instance.captureAllowed, instance.page === page { capture(instance) }
            }
            do {
                while instance.needsSnapshot, instance.page === page {
                    if !instance.preparing {
                        try await Task.sleep(for: .milliseconds(180))
                        try Task.checkCancellation()
                        guard instance.captureAllowed else { return }
                    }
                    instance.needsSnapshot = false
                    guard let key = instance.key else { return }
                    let height = min(max(1, instance.height), instance.inlineHeightLimit)
                    let signposter = AppPerformanceDiagnostics.pointsOfInterest
                    let signpostID = signposter.makeSignpostID()
                    let interval = signposter.beginInterval("HTMLVisualSnapshot", id: signpostID)
                    #if DEBUG
                    Self.logger.notice("html visual snapshot began id=\(signpostID.rawValue)")
                    #endif
                    let data: Data
                    let activity = instance.activity
                    let captureStarted = ContinuousClock.now
                    activity?.capturesStarted += 1
                    do {
                        defer {
                            signposter.endInterval("HTMLVisualSnapshot", interval)
                            activity?.captureDuration += captureStarted.duration(to: .now)
                        }
                        data = try await page.exported(as: .pdf(
                            region: .rect(CGRect(x: 0, y: 0, width: CGFloat(key.width), height: height)),
                            allowTransparentBackground: true))
                        activity?.capturesCompleted += 1
                    }
                    #if DEBUG
                    Self.logger.notice("html visual snapshot completed id=\(signpostID.rawValue) bytes=\(data.count)")
                    #endif
                    try Task.checkCancellation()
                    guard instance.page === page, instance.key == key else { continue }
                    let captured = try await store(data, for: key, height: instance.height)
                    guard instance.page === page, instance.key == key else { continue }
                    guard let captured else {
                        instance.capturedImage = nil
                        Self.logger.notice("html visual snapshot discarded bytes=\(data.count) limit=\(HTMLVisualCapturedImage.maximumBytes)")
                        continue
                    }
                    instance.snapshot = snapshot(for: key)
                    instance.capturedImage = captured
                    instance.onCaptureFinished()
                }
            } catch is CancellationError {
            } catch HTMLVisualPresentationError.capacity {
                guard instance.page === page else { return }
                instance.needsSnapshot = false
                instance.onCaptureFinished()
            } catch {
                instance.needsSnapshot = false
                Self.logger.error("html visual snapshot failed reason=\(error.localizedDescription)")
            }
        }
    }

    func store(_ data: Data, for key: HTMLVisualLayoutKey, height: Double) async throws -> HTMLVisualCapturedImage? {
        guard let captured = HTMLVisualCapturedImage(data: data, key: key, revision: nextSnapshotRevision()) else { return nil }
        pendingHeights.removeValue(forKey: key)
        let snapshot = try await cache.store(key, height: height, image: data, protecting: Set(rasterPins.keys))
        persistedImages.apply(snapshot)
        if let current = snapshots[key], current.revision > captured.revision { return captured }
        heights[key] = height
        heightOrder.removeAll { $0 == key }
        heightOrder.append(key)
        if heightOrder.count > HTMLVisualPresentationCache.maximumHeights { heights.removeValue(forKey: heightOrder.removeFirst()) }
        let cached = snapshot(for: key)
        cached.height = height
        cached.image = data
        cached.byteCount = data.count
        cached.revision = captured.revision
        snapshotOrder.removeAll { $0 == key }
        snapshotOrder.append(key)
        for stale in rasterOrder where stale.key == key && stale.revision < captured.revision { superseded.insert(stale) }
        trimSnapshots()
        return captured
    }

    func setCaptureAllowed(_ instance: HTMLVisualInstance, _ allowed: Bool) {
        guard instance.captureAllowed != allowed else { return }
        instance.captureAllowed = allowed
        if !allowed, let capture = instance.capture {
            instance.needsSnapshot = true
            capture.cancel()
        }
        else if allowed, instance.needsSnapshot { capture(instance) }
    }

    private func persistHeight(_ height: Double, for key: HTMLVisualLayoutKey) {
        if pendingHeights.count >= HTMLVisualPresentationCache.maximumHeights,
           pendingHeights[key] == nil, let first = pendingHeights.keys.first {
            pendingHeights.removeValue(forKey: first)
        }
        pendingHeights[key] = height
        guard persistence == nil else { return }
        persistence = Task {
            defer { persistence = nil }
            while let (key, height) = pendingHeights.first {
                pendingHeights.removeValue(forKey: key)
                do {
                    let snapshot = try await cache.store(key, height: height, image: nil, protecting: Set(rasterPins.keys))
                    persistedImages.apply(snapshot)
                } catch { Self.logger.error("html visual cache save failed reason=\(error.localizedDescription)") }
                if Task.isCancelled { return }
            }
        }
    }

    private func trimSnapshots() {
        var bytes = snapshots.values.reduce(0) { $0 + $1.byteCount }
        while snapshotOrder.count > HTMLVisualPresentationCache.maximumHeights || bytes > HTMLVisualPresentationCache.maximumImageBytes {
            let key = snapshotOrder.removeFirst()
            if let snapshot = snapshots.removeValue(forKey: key) {
                bytes -= snapshot.byteCount
                snapshot.image = nil
                snapshot.byteCount = 0
            }
        }
    }
}
