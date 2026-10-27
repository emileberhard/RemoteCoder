#if os(macOS)
import AppKit
import QuartzCore
import OSLog
import SwiftUI

#if RC_PERF_HARNESS
extension EnvironmentValues {
    @Entry var perfTranscriptAddress: ConversationAddress?
}
#endif

struct TranscriptNativeGeometry: Equatable {
    let height: CGFloat
    let columnWidth: Int?
    let isNearTop: Bool
    let isAtBottom: Bool
    let isFarFromLatest: Bool?
    let isRunwayShort: Bool?
}

enum TranscriptNativeEvent {
    case geometry(TranscriptNativeGeometry)
    case visibility(Set<String>)
    case phase(ScrollPhase, atBottom: Bool)
    case userMoved(atBottom: Bool)
    case userCancelled
}

@MainActor
final class TranscriptNativeEndpoint {
    private weak var container: AppKitTranscriptContainer?

    func attach(_ container: AppKitTranscriptContainer) { self.container = container }
    func detach(_ container: AppKitTranscriptContainer) {
        if self.container === container { self.container = nil }
    }

    func scrollTo(id: String, anchor: UnitPoint?, animated: Bool, completion: @escaping () -> Void) {
        container?.alignRow(id, anchor: anchor, animated: animated, completion: completion)
    }

    func latest(animated: Bool) { container?.showLatest(animated: animated) }
    func suspend() { container?.suspend() }
    func resume() { container?.resume() }
}

struct AppKitTranscriptScrollView<Content: View>: NSViewRepresentable {
    let presentation: TranscriptNativePresentation
    let retention: TranscriptSurfaceRetention.Scope?
    let readingPosition: TranscriptReadingPosition
    let rowPresentations: TranscriptRowPresentations
    let readingScope: UUID
    let rows: [TranscriptRowInputs]
    let renderedMessages: RenderedMessageStore
    let reservedBottom: CGFloat
    let isFollowingLatest: () -> Bool
    let onEvent: (TranscriptNativeEvent) -> Void
    let onNavigate: (TranscriptScrollHalt.Navigation) -> Void
    @ViewBuilder let rowContent: (TranscriptRowInputs) -> Content
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(TranscriptCodeExportPresenter.self) private var codeExportPresenter

    func makeNSView(context: Context) -> AppKitTranscriptContainer {
        let saved = retention?.take(for: readingPosition) as? AppKitTranscriptContainer
        let view = saved ?? AppKitTranscriptContainer(presentation: presentation, readingPosition: readingPosition, readingScope: readingScope)
        if saved != nil {
            view.restoreSavedReadingPosition(readingPosition)
            PerfBuild.count("native.surfaceReused")
        }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AppKitTranscriptContainer, context: Context) {
        view.bindRetention(retention)
        view.bindReadingPosition(readingPosition)
        view.isFollowingLatest = isFollowingLatest
        view.onEvent = onEvent
        view.onNavigate = onNavigate
        var environment = context.environment
        environment.transcriptSurfaceRetention = nil
        #if RC_PERF_HARNESS
        view.bindAddressForBench(environment.perfTranscriptAddress)
        #endif
        view.setRows(rows, presentations: rowPresentations, renderedMessages: renderedMessages, reservedBottom: reservedBottom, environment: environment,
                     environmentInputs: TranscriptHostEnvironment(environment, themeStore: themeStore,
                                                                  codeExportPresenter: codeExportPresenter),
                     content: rowContent)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppKitTranscriptContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    static func dismantleNSView(_ view: AppKitTranscriptContainer, coordinator: ()) { view.detachSurface() }
}

final class AppKitTranscriptContainer: NSScrollView, TranscriptReadingPositionCapturing, RetainedTranscriptSurface {
    #if RC_PERF_HARNESS
    private(set) var presentedAddressForBench: ConversationAddress?

    func bindAddressForBench(_ address: ConversationAddress?) {
        guard let address else { return }
        precondition(presentedAddressForBench == nil || presentedAddressForBench == address)
        presentedAddressForBench = address
    }
    #endif
    var isFollowingLatest: () -> Bool = { true }
    var onEvent: (TranscriptNativeEvent) -> Void = { _ in }
    var onNavigate: (TranscriptScrollHalt.Navigation) -> Void = { _ in }

    let presentation: TranscriptNativePresentation
    private let readingScope: UUID
    private var endpoint: TranscriptNativeEndpoint { presentation.endpoint }
    private var halt: TranscriptScrollHalt { presentation.halt }
    private weak var readingPosition: TranscriptReadingPosition?
    private var retention: TranscriptSurfaceRetention.Scope?
    private var readingRestoration: TranscriptReadingRestoration?
    private var readingReadinessTask: Task<Void, Never>?
    private var restoringReadingAnchor: TranscriptReadingAnchor? { readingRestoration?.pendingAnchor }
    private let transcriptDocument = AppKitTranscriptDocument()
    private static let logger = AppLogger(category: "Transcript")
    private var logicalRows: [String: TranscriptLogicalRow] = [:]
    private var rowPresentationOwner: ObjectIdentifier?
    private var rowHosts: [String: TranscriptRowHost] = [:]
    private var rowContent: ((TranscriptRowInputs) -> AnyView)?
    private var renderedMessages: RenderedMessageStore?
    private var pinnedRows: Set<String> = []
    private var interactionRowID: String?
    private var hostsDirty = true
    private var admissionPending = false
    private var admissionsThisFrame = 0
    private var admissionElapsed: CFTimeInterval = 0
    private var preparation: Task<Void, Never>?
    private var preparingIDs: Set<UUID> = []
    private var preparationSerial = 0
    private var columnWidth: CGFloat?
    private var reflowAnchor: TranscriptRowIndex.PreservationAnchor?
    private var rowOrder: [String] = []
    private var dirtyHosts: Set<String> = []
    private var environment: EnvironmentValues?
    private var environmentInputs: TranscriptHostEnvironment?
    private var readingLayoutCache = TranscriptReadingLayoutCache<TranscriptHostEnvironment>()
    private var reservedBottom: CGFloat = 0
    private var contentRevision = 0
    private var committedContentRevision = -1
    private var index: TranscriptRowIndex?
    private var hitCache: HitCache?

    private struct HitCache {
        let point: CGPoint
        weak var host: TranscriptRowHost?
        let frame: CGRect
        let rootRevision: Int
        let renderRevision: Int?
        let createdAt: CFTimeInterval
        weak var result: NSView?
    }
    private var geometryDirty = true
    private var committedViewportSize: CGSize?
    private var commitScheduled = false
    private var isCommitting = false
    private var commitRequested = false
    private var isTornDown = false
    private var initialBottom = true
    private var eventMonitor: Any?
    private var idleTimer: Timer?
    private var phase = ScrollPhase.idle
    private var idlePending = false
    private enum WheelAxis { case unresolved, horizontal, vertical }
    private enum WheelGesture { case horizontal, vertical, ownedVertical, draining }
    private var wheelGesture: WheelGesture?
    private var ownsWheelGesture: Bool { wheelGesture == .ownedVertical || wheelGesture == .draining }
    private var samplePending = false
    private var lastGeometry: TranscriptNativeGeometry?
    private var lastVisibleIDs: Set<String>?
    private var userInputOrigin: CGFloat?
    private var lastUserBottom: Bool?
    private var userHasMoved: Bool { lastUserBottom != nil }
    private var isWritingGeometry = false
    private var selectionTracking = false
    private var wheelEventAxis: WheelAxis?
    private var isSuspended = false
    private var observesNativeLifecycle = false
    private var frameLink: CADisplayLink?
    private let frameTarget = TranscriptDisplayLinkTarget()
    private var intentSerial = 0
    private var command: Command?
    private var animation: ScrollAnimation?

    private struct Command {
        enum Destination { case row(String, UnitPoint?), latest }
        let serial: Int
        let destination: Destination
        let animated: Bool
        let minimumContentRevision: Int
        let completion: () -> Void
    }

    private struct ScrollAnimation {
        let serial: Int
        let from: CGFloat
        let destination: Command.Destination
        let start: CFTimeInterval
    }

    func bindReadingPosition(_ position: TranscriptReadingPosition) {
        readingPosition?.detach(self, scope: readingScope)
        readingPosition = position
        position.attach(self, scope: readingScope)
    }

    func restoreSavedReadingPosition(_ position: TranscriptReadingPosition) {
        let current = readingAnchor(in: documentViewport)
        if position.isFollowingLatest {
            cancelReadingRestoration()
            initialBottom = !atBottom
            if initialBottom { geometryDirty = true }
        } else if let anchor = position.anchor, !anchor.matchesDisplayedPoint(current) {
            beginReadingRestoration(anchor)
            if let row = logicalRows[anchor.rowID], rowHosts[anchor.rowID] == nil { row.height = anchor.rowHeight }
            geometryDirty = true
            hostsDirty = true
        } else {
            cancelReadingRestoration()
        }
    }

    private func beginReadingRestoration(_ anchor: TranscriptReadingAnchor) {
        readingReadinessTask?.cancel()
        readingReadinessTask = nil
        readingRestoration = TranscriptReadingRestoration(anchor: anchor,
            deadline: .now + TranscriptReadingRestoration.renderReadinessTimeout)
        checkReadingSource()
        startReadingReadiness()
    }

    private func checkReadingSource() {
        guard var pending = readingRestoration, pending.isPending, rowContent != nil else { return }
        pending.sourceChanged(containsTarget: logicalRows[pending.anchor.rowID] != nil)
        readingRestoration = pending
        if let result = pending.result { readingRestorationEnded(result) }
    }

    private func startReadingReadiness() {
        guard !isTornDown, !isSuspended, window != nil, readingReadinessTask == nil,
              let pending = readingRestoration, pending.isPending else { return }
        let deadline = pending.deadline
        readingReadinessTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: ContinuousClock()) } catch { return }
            guard !Task.isCancelled, let self, !self.isTornDown, !self.isSuspended, self.window != nil,
                  var pending = self.readingRestoration, pending.isPending, pending.deadline == deadline else { return }
            pending.expire(at: .now)
            self.readingRestoration = pending
            if let result = pending.result { self.readingRestorationEnded(result) }
        }
    }

    private func finishReadingRestoration(_ outcome: TranscriptReadingRestoration.Outcome) {
        guard var pending = readingRestoration, pending.isPending else { return }
        pending.terminate(outcome)
        readingRestoration = pending
        if let result = pending.result { readingRestorationEnded(result) }
    }

    private func readingRestorationEnded(_ result: TranscriptReadingRestoration.Result) {
        readingReadinessTask?.cancel()
        readingReadinessTask = nil
        readingPosition?.recordRestorationOutcome(result)
        if reflowAnchor?.rowID == result.rowID { reflowAnchor = nil }
        if result.outcome.preservesBookmark {
            Self.logger.notice("Reading position unavailable row=\(result.rowID) outcome=\(result.outcome.rawValue); kept known bookmark")
            hostsDirty = true
            scheduleCommit()
        }
    }

    private func cancelReadingRestoration() {
        finishReadingRestoration(.cancelled)
        readingReadinessTask?.cancel()
        readingReadinessTask = nil
        readingRestoration = nil
    }

    func bindRetention(_ retention: TranscriptSurfaceRetention.Scope?) {
        self.retention = retention
        presentation.activity.state = .mounted
        renderedMessages?.retainedTranscripts = retention?.cache
    }

    init(presentation: TranscriptNativePresentation, readingPosition: TranscriptReadingPosition, readingScope: UUID) {
        self.presentation = presentation
        self.readingScope = readingScope
        self.readingPosition = readingPosition
        readingRestoration = readingPosition.anchor.map {
            TranscriptReadingRestoration(anchor: $0, deadline: .now + TranscriptReadingRestoration.renderReadinessTimeout)
        }
        initialBottom = readingPosition.isFollowingLatest
        super.init(frame: .zero)
        readingPosition.attach(self, scope: readingScope)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        #if RC_PERF_HARNESS
        contentView = TranscriptHarnessClipView()
        contentView.drawsBackground = false
        #endif
        contentView.postsBoundsChangedNotifications = true
        allowsMagnification = false
        automaticallyAdjustsContentInsets = false
        transcriptDocument.translatesAutoresizingMaskIntoConstraints = false
        transcriptDocument.autoresizesSubviews = false
        transcriptDocument.container = self
        documentView = transcriptDocument
        endpoint.attach(self)
        frameTarget.container = self
        observeNativeLifecycle()
    }

    private func observeNativeLifecycle() {
        guard !observesNativeLifecycle else { return }
        observesNativeLifecycle = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(beginLiveScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(endLiveScroll), name: NSScrollView.didEndLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(windowVisibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    #if RC_PERF_HARNESS
    override class var isCompatibleWithResponsiveScrolling: Bool {
        !PerfBuild.disabled.contains("responsiveScrolling")
    }
    #endif

    func setRows<Content: View>(_ rows: [TranscriptRowInputs], presentations: TranscriptRowPresentations, renderedMessages: RenderedMessageStore,
                                reservedBottom: CGFloat, environment: EnvironmentValues,
                                environmentInputs: TranscriptHostEnvironment,
                                content: @escaping (TranscriptRowInputs) -> Content) {
        let span = PerfBuild.span("native.root"); defer { span.end() }
        let order = rows.map { $0.row.id }
        let ids = Set(order)
        guard ids.count == order.count, !ids.contains(TranscriptAnchor.bottom) else {
            PerfBuild.count("native.rowsRejected")
            Self.logger.error("Rejected transcript rows with duplicate or reserved identities")
            return
        }
        let environmentChanged = self.environmentInputs != environmentInputs || self.renderedMessages !== renderedMessages
            || rowPresentationOwner != ObjectIdentifier(presentations)
        rowPresentationOwner = ObjectIdentifier(presentations)
        if let previous = self.environmentInputs, environmentInputs.reflows(comparedTo: previous) {
            reflowAnchor = reflowAnchor ?? readingAnchor(in: documentViewport)
        }
        self.environment = environment
        self.environmentInputs = environmentInputs
        if self.renderedMessages !== renderedMessages { cancelPreparation() }
        self.renderedMessages = renderedMessages
        renderedMessages.retainedTranscripts = retention?.cache
        rowContent = { AnyView(content($0)) }
        var changed = rowOrder != order || self.reservedBottom != reservedBottom || environmentChanged
        self.reservedBottom = reservedBottom
        for id in rowOrder where !ids.contains(id) {
            logicalRows.removeValue(forKey: id)?.presentation.onPinChange = { _ in }
            removeHost(id)
            pinnedRows.remove(id)
            if interactionRowID == id { interactionRowID = nil }
        }
        rowOrder = order
        for inputs in rows {
            let id = inputs.row.id
            if let row = logicalRows[id] {
                row.presentation.bind(to: presentations)
                guard environmentChanged || row.inputs != inputs else {
                    if rowHosts[id] != nil { PerfBuild.count("native.rowHostRetained") }
                    continue
                }
                row.inputs = inputs
            } else {
                let row = TranscriptLogicalRow(inputs: inputs, presentations: presentations,
                                               rendered: inputs.row.message.flatMap { renderedMessages[$0.id] }, width: max(320, min(contentView.bounds.width - 32,
                                                                  ReadableContentWidth.transcript * environmentInputs.interfaceScale)),
                                               scale: environmentInputs.interfaceScale, htmlVisualTheme: environmentInputs.htmlVisualTheme,
                                               htmlVisualRenderer: environmentInputs.htmlVisualSource?.renderer)
                if let anchor = restoringReadingAnchor, anchor.rowID == id { row.height = anchor.rowHeight }
                row.presentation.onPinChange = { [weak self] pinned in
                    guard let self, self.logicalRows[id] != nil else { return }
                    if pinned { self.pinnedRows.insert(id) } else { self.pinnedRows.remove(id) }
                    self.hostsDirty = true
                    self.scheduleCommit()
                }
                logicalRows[id] = row
            }
            if let host = rowHosts[id] { updateHost(host) }
            changed = true
        }
        checkReadingSource()
        guard changed else { return }
        if environmentChanged { PerfBuild.count("native.rowEnvironmentChanged") }
        contentRevision += 1
        geometryDirty = true
        hostsDirty = true
        scheduleCommit()
    }

    private func updateHost(_ host: TranscriptRowHost) {
        guard let row = logicalRows[host.inputs.row.id], let environment, let rowContent else { return }
        host.update(inputs: row.inputs,
                    content: rowContent(row.inputs).environment(\.transcriptRowPresentation, row.presentation)
                        .environment(\.transcriptSurfaceActivity, presentation.activity),
                    environment: environment)
        dirtyHosts.insert(row.inputs.row.id)
    }

    private func removeHost(_ id: String) {
        guard let host = rowHosts.removeValue(forKey: id) else { return }
        host.remove()
        dirtyHosts.remove(id)
        PerfBuild.count("native.hostUnmounted")
    }

    fileprivate func scheduleCommit() {
        guard !isTornDown, !isSuspended else { return }
        if isCommitting {
            commitRequested = true
            return
        }
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.commitScheduled = false
            guard !self.isTornDown, !self.isSuspended else { return }
            self.commitLayout()
        }
    }

    fileprivate func rowView(at point: CGPoint) -> NSView? {
        guard let id = index?.rowID(at: point.y), let host = rowHosts[id] else {
            PerfBuild.count("hit.documentGap")
            return nil
        }
        PerfBuild.count("hit.rowCandidate")
        let frame = host.view.frame
        guard frame.contains(point) else { return nil }
        let renderRevision = host.inputs.row.message.flatMap { renderedMessages?[$0.id]?.revision }
        let now = CACurrentMediaTime()
        if let hitCache, hitCache.point == point, hitCache.host === host,
           hitCache.frame == frame, hitCache.rootRevision == host.rootRevision,
           hitCache.renderRevision == renderRevision, now - hitCache.createdAt < 0.1,
           let result = hitCache.result,
           result === host.view || result.isDescendant(of: host.view) {
            PerfBuild.count("hit.cacheHit")
            return result
        }
        PerfBuild.count("hit.cacheMiss")
        PerfBuild.count("hit.rowShortcut")
        let result = host.view.hitTest(point)
        hitCache = HitCache(point: point, host: host, frame: frame,
            rootRevision: host.rootRevision, renderRevision: renderRevision,
            createdAt: now, result: result)
        return result
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if routesCurrentWheelVertically, !isHidden,
           contentView.bounds.contains(contentView.convert(point, from: superview)) {
            PerfBuild.count("hit.container")
            return self
        }
        return super.hitTest(point)
    }

    fileprivate var routesCurrentWheelVertically: Bool {
        if let wheelEventAxis { return wheelEventAxis == .vertical }
        guard let event = NSApp.currentEvent, event.type == .scrollWheel, event.window === window else { return false }
        return wheelAxis(for: event) == .vertical
    }

    private func wheelAxis(for event: NSEvent) -> WheelAxis {
        let startsGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        let direction = startsGesture || (event.phase.isEmpty && event.momentumPhase.isEmpty) ? nil : wheelGesture
        if let direction { return direction == .horizontal ? .horizontal : .vertical }
        guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return .unresolved }
        return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? .vertical : .horizontal
    }

    override func layout() {
        let span = PerfBuild.span("native.layout"); defer { span.end() }
        super.layout()
        if contentView.bounds.size != committedViewportSize {
            geometryDirty = true
            scheduleCommit()
        }
    }

    private func commitLayout() {
        let span = PerfBuild.span("native.commit"); defer { span.end() }
        guard !isCommitting, let environmentInputs, let window else { return }
        let scale = window.backingScaleFactor
        let viewportSize = contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        guard geometryDirty || hostsDirty || !dirtyHosts.isEmpty || command != nil
                || committedViewportSize != viewportSize else { return }
        isCommitting = true
        defer {
            isCommitting = false
            if commitRequested {
                commitRequested = false
                scheduleCommit()
            }
        }
        let previousViewport = documentViewport
        let target = restoringReadingAnchor ?? reflowAnchor ?? readingAnchor(in: previousViewport)
        let width = max(1, min(viewportSize.width - 32, ReadableContentWidth.transcript * environmentInputs.interfaceScale))
        if columnWidth != width {
            reflowAnchor = target
            columnWidth = width
            for (id, host) in rowHosts {
                host.propose(width: width)
                dirtyHosts.insert(id)
            }
            geometryDirty = true
            hostsDirty = true
        }
        let measuring = dirtyHosts
        dirtyHosts.removeAll(keepingCapacity: true)
        for id in measuring { rowHosts[id]?.layoutIfNeeded() }
        if geometryDirty || committedContentRevision != contentRevision || committedViewportSize != viewportSize {
            guard commitGeometry(viewportSize: viewportSize, scale: scale) else { return }
            if !executeCommand() {
                if animation != nil {
                    scroll(to: previousViewport.minY)
                } else if let anchor = restoringReadingAnchor,
                          let destination = index?.origin(restoring: anchor, viewport: documentViewport,
                                                       layout: readingLayout(columnWidth: width, environment: environmentInputs)) {
                    scroll(to: destination)
                    PerfBuild.count("transcriptRestorations")
                } else if command == nil, initialBottom || (isFollowingLatest() && (!isUserScrolling || !userHasMoved)) {
                    PerfBuild.count(initialBottom ? "write.initial" : "write.follow")
                    initialBottom = false
                    scroll(to: maximumOrigin)
                } else if let target, let destination = reflowAnchor != nil
                            ? index?.origin(reflowing: target, viewport: documentViewport)
                            : index?.origin(preserving: target, viewport: documentViewport) {
                    scroll(to: destination)
                    PerfBuild.count("transcriptRestorations")
                } else {
                    PerfBuild.count(target == nil ? "restore.noTarget" : "restore.missing")
                    scroll(to: previousViewport.minY)
                }
            }
        } else {
            _ = executeCommand()
        }
        reconcileHosts(width: width)
        let placementSpan = PerfBuild.span("native.placement")
        let x = Self.pixelAligned((viewportSize.width - width) / 2, scale: scale, .toNearestOrAwayFromZero)
        for (id, host) in rowHosts {
            guard let placement = index?.row(for: id), let measurement = host.measurement,
                  abs(Self.pixelAligned(measurement.height, scale: scale) - (placement.maxY - placement.minY)) < 0.001,
                  host.hasMeasurement(for: width) else { continue }
            host.place(in: CGRect(x: x, y: placement.minY, width: width, height: placement.maxY - placement.minY))
        }
        placementSpan.end()
        if let anchor = restoringReadingAnchor, let placement = index?.row(for: anchor.rowID),
           let host = rowHosts[anchor.rowID], let measurement = host.measurement,
           host.hasMeasurement(for: width),
           abs(Self.pixelAligned(measurement.height, scale: scale) - (placement.maxY - placement.minY)) < 0.001 {
            finishReadingRestoration(.completed)
        }
        if let target = reflowAnchor {
            if index?.row(for: target.rowID) == nil {
                reflowAnchor = nil
            } else if let placement = index?.row(for: target.rowID),
                      let host = rowHosts[target.rowID], let measurement = host.measurement,
                      host.hasMeasurement(for: width),
                      abs(Self.pixelAligned(measurement.height, scale: scale)
                        - (placement.maxY - placement.minY)) < 0.001 {
                reflowAnchor = nil
            }
        }
        #if RC_PERF_HARNESS
        PerfBuild.gauge("transcriptSubviews", rowHosts.count)
        PerfBuild.gauge("transcriptRowHosts", rowHosts.count)
        PerfBuild.gauge("transcriptLogicalRows", logicalRows.count)
        #endif
        markSampleDirty()
    }

    private static func pixelAligned(_ value: CGFloat, scale: CGFloat, _ rule: FloatingPointRoundingRule = .up) -> CGFloat {
        (value * scale).rounded(rule) / scale
    }

    private func commitGeometry(viewportSize: CGSize, scale: CGFloat) -> Bool {
        var heights: [CGFloat] = []
        heights.reserveCapacity(rowOrder.count + 1)
        for id in rowOrder {
            guard let row = logicalRows[id] else { return false }
            heights.append(Self.pixelAligned(row.height, scale: scale))
        }
        let bottomHeight = Self.pixelAligned(20 + reservedBottom, scale: scale)
        heights.append(bottomHeight)
        let latestTurnIndex = rowOrder.lastIndex { logicalRows[$0]?.inputs.row.startsTurn == true }
        let tail = Self.pixelAligned(TranscriptLayout.tailPadding(heights: heights, latestTurnIndex: latestTurnIndex,
                                                                  minimumTurnHeight: viewportSize.height - reservedBottom), scale: scale)
        let survivorID = rowOrder.first {
            logicalRows[$0]?.inputs.row.isReadingTarget == true && index?.row(for: $0) != nil
        } ?? rowOrder.first { index?.row(for: $0) != nil }
        var firstY = Self.pixelAligned(transcriptDocument.bounds.minY, scale: scale, .toNearestOrAwayFromZero) + 12
        var prefixHeight: CGFloat = 0
        for (position, id) in rowOrder.enumerated() {
            if id == survivorID, let previous = index?.row(for: id) {
                let survivorY = Self.pixelAligned(previous.minY, scale: scale, .toNearestOrAwayFromZero)
                firstY = survivorY - prefixHeight
                break
            }
            prefixHeight += heights[position] + TranscriptLayout.spacing
        }
        let documentTop = firstY - 12
        var placements: [TranscriptRowIndex.Row] = []
        placements.reserveCapacity(heights.count)
        var y = firstY
        for (position, id) in rowOrder.enumerated() {
            guard let row = logicalRows[id]?.inputs.row else { return false }
            placements.append(.init(id: id, role: row.isReadingTarget ? .reading : .content,
                                    startsTurn: row.startsTurn, mountCost: row.mountCost,
                                    minY: y, maxY: y + heights[position]))
            y += heights[position] + TranscriptLayout.spacing
        }
        y += tail
        let documentBottom = y + bottomHeight
        placements.append(.init(id: TranscriptAnchor.bottom, role: .bottom, startsTurn: false, mountCost: 0,
                                minY: y, maxY: documentBottom))
        let documentSize = CGSize(width: viewportSize.width,
                                  height: max(documentBottom - documentTop, Self.pixelAligned(viewportSize.height, scale: scale)))
        let bounds = CGRect(origin: CGPoint(x: 0, y: documentTop), size: documentSize)
        guard let nextIndex = TranscriptRowIndex(rows: placements, bounds: bounds) else { return false }
        isWritingGeometry = true
        defer { isWritingGeometry = false }
        geometryDirty = false
        let resizeSpan = PerfBuild.span("native.documentResize")
        if transcriptDocument.frame.size != documentSize { transcriptDocument.setFrameSize(documentSize) }
        if transcriptDocument.bounds != bounds {
            transcriptDocument.bounds = bounds
            transcriptDocument.needsDisplay = true
        }
        resizeSpan.end()
        index = nextIndex
        committedViewportSize = viewportSize
        committedContentRevision = contentRevision
        hostsDirty = true
        PerfBuild.count("transcriptIndexCommits")
        return true
    }

    private func reconcileHosts(width: CGFloat) {
        guard let index, let renderedMessages else { return }
        let viewport = documentViewport
        let visible = index.rows(in: viewport).filter { $0.role != .bottom }.map(\.id)
        let ahead = index.rows(in: viewport.insetBy(dx: 0, dy: -viewport.height))
            .filter { $0.role != .bottom }.map(\.id)
        let retained = Set(index.rows(in: viewport.insetBy(dx: 0, dy: -viewport.height * 2)).map(\.id))
        var required = pinnedRows
        if let reflowAnchor { required.insert(reflowAnchor.rowID) }
        if let restoringReadingAnchor { required.insert(restoringReadingAnchor.rowID) }
        if let interactionRowID { required.insert(interactionRowID) }
        if let responder = window?.firstResponder as? NSView {
            for (id, host) in rowHosts where responder === host.view || responder.isDescendant(of: host.view) { required.insert(id) }
        }
        if let anchor = readingAnchor(in: viewport) { required.insert(anchor.rowID) }
        let destination = command?.destination ?? animation?.destination
        var targetID: String? = restoringReadingAnchor?.rowID
        if case .row(let id, _)? = destination { targetID = id; required.insert(id) }
        var ordered = targetID.map { [$0] } ?? []
        ordered += isFollowingLatest() ? Array(visible.reversed()) : visible
        func nearestFirst(_ ids: [String]) -> [String] {
            ids.map { ($0, abs((index.row(for: $0)?.minY ?? 0) - viewport.midY)) }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        ordered += required.sorted()
        ordered += nearestFirst(ahead)
        var desired = required.union(visible)
        let capacity = max(96, desired.count)
        for id in ordered where desired.count < capacity { desired.insert(id) }
        let retainedHosts = nearestFirst(rowHosts.keys.filter(retained.contains))
        for id in retainedHosts where desired.count < capacity { desired.insert(id) }
        for id in Array(rowHosts.keys) where !desired.contains(id) { removeHost(id) }
        hostsDirty = false
        admissionPending = false
        var visited: Set<String> = []
        var missing: [ChatMessage] = []
        for id in ordered where desired.contains(id) && visited.insert(id).inserted {
            guard rowHosts[id] == nil, let row = logicalRows[id] else { continue }
            if let message = row.inputs.row.message, !renderedMessages.hasRendered([message]) {
                if missing.count < 32 { missing.append(message) }
                continue
            }
            guard admissionsThisFrame < 4, admissionsThisFrame == 0 || admissionElapsed < 0.004 else {
                admissionPending = true
                PerfBuild.count("native.hostAdmissionDeferred")
                continue
            }
            let admissionStarted = CACurrentMediaTime()
            admissionsThisFrame += 1
            let host = TranscriptRowHost(inputs: row.inputs)
            #if RC_PERF_HARNESS
            if let indexedRow = index.row(for: id) {
                host.admissionForBench = .init(row: CGRect(x: viewport.minX, y: indexedRow.minY,
                    width: viewport.width, height: indexedRow.maxY - indexedRow.minY),
                    viewport: viewport, required: required.contains(id))
            }
            #endif
            host.surfaceActivity = presentation.activity
            rowHosts[id] = host
            host.onMeasurement = { [weak self, weak host] in
                guard let self, let host, self.rowHosts[id] === host, let row = self.logicalRows[id],
                      let size = host.measurement, !self.isTornDown else {
                    PerfBuild.count("native.rowMeasurementStale")
                    return
                }
                if row.height != size.height {
                    if let window = self.window {
                        self.geometryDirty = self.geometryDirty
                            || Self.pixelAligned(row.height, scale: window.backingScaleFactor)
                                != Self.pixelAligned(size.height, scale: window.backingScaleFactor)
                    } else {
                        self.geometryDirty = true
                    }
                    row.height = size.height
                }
                self.hostsDirty = true
                self.scheduleCommit()
            }
            transcriptDocument.addSubview(host.view)
            updateHost(host)
            host.propose(width: width)
            dirtyHosts.remove(id)
            host.layoutIfNeeded()
            admissionElapsed += CACurrentMediaTime() - admissionStarted
            PerfBuild.count("native.hostMounted")
            PerfBuild.count("revealRows")
        }
        prepare(missing, with: renderedMessages)
    }

    private func prepare(_ messages: [ChatMessage], with store: RenderedMessageStore) {
        let ids = Set(messages.map(\.id))
        guard !ids.isEmpty else { return }
        let urgentID: UUID?
        if case .row(let id, _)? = command?.destination { urgentID = logicalRows[id]?.inputs.row.message?.id }
        else { urgentID = restoringReadingAnchor.flatMap { logicalRows[$0.rowID]?.inputs.row.message?.id } }
        if preparation != nil, !preparingIDs.isDisjoint(with: ids),
           urgentID.map(preparingIDs.contains) ?? true { return }
        cancelPreparation()
        let serial = preparationSerial
        preparingIDs = ids
        PerfBuild.count("native.hostPreparationBatches")
        preparation = Task { [weak self] in
            await store.prepareMounting(messages)
            guard let self, !Task.isCancelled, !self.isTornDown, serial == self.preparationSerial else { return }
            self.preparation = nil
            self.preparingIDs = []
            self.hostsDirty = true
            self.scheduleCommit()
        }
    }

    private func cancelPreparation() {
        preparationSerial += 1
        preparation?.cancel()
        preparation = nil
        preparingIDs = []
    }

    private func readingAnchor(in viewport: CGRect) -> TranscriptRowIndex.PreservationAnchor? {
        guard let columnWidth, let environmentInputs else { return nil }
        let hostedIDs = Set(rowHosts.compactMap { $0.value.view.alphaValue == 1 ? $0.key : nil })
        return index?.preservationAnchor(in: viewport, among: hostedIDs,
            layout: readingLayout(columnWidth: columnWidth, environment: environmentInputs))
    }

    private func readingLayout(columnWidth: CGFloat, environment: TranscriptHostEnvironment) -> TranscriptReadingLayout {
        readingLayoutCache.layout(environment: environment, columnWidth: columnWidth) {
            environment.readingLayout(columnWidth: columnWidth)
        }
    }

    #if RC_PERF_HARNESS
    struct HostWorkForBench {
        let viewport: CGRect
        let displayScale: CGFloat?
        let followingLatest: Bool
        let latestDistance: CGFloat
        let readingPoint: (rowID: String, offset: CGFloat)?
        var rows: [String: TranscriptRowHost.WorkForBench]

        var positionOwnerY: CGFloat? {
            if followingLatest { return viewport.maxY + latestDistance }
            guard let point = readingPoint, let row = rows[point.rowID]?.rowFrame else { return nil }
            return row.minY + point.offset
        }
    }

    func hostWorkForBench() -> HostWorkForBench {
        let viewport = documentViewport
        return HostWorkForBench(viewport: viewport, displayScale: window?.backingScaleFactor,
            followingLatest: isFollowingLatest(), latestDistance: latestDistanceForBench,
            readingPoint: readingPositionForBench().map { ($0.rowID, $0.offset) },
            rows: rowHosts.mapValues { host in
                let frame = index?.row(for: host.inputs.row.id).map {
                    CGRect(x: viewport.minX, y: $0.minY, width: viewport.width, height: $0.maxY - $0.minY)
                }
                return host.workForBench(rowFrame: frame)
            })
    }

    var isLayoutReadyForBench: Bool { isLayoutReady }
    var latestDistanceForBench: CGFloat { maximumOrigin - documentViewport.minY }

    func hostedRowForBench(id: String) -> NSView? { rowHosts[id]?.view }

    func unavailableReadingForBench() async throws -> (sourceRemoved: Bool, renderUnavailable: Bool, explicitRetry: Bool)? {
        guard let environment, let environmentInputs, let parent = window?.contentView,
              let inputs = rowOrder.compactMap({ logicalRows[$0]?.inputs }).first(where: { $0.row.message != nil }),
              let saved = TranscriptReadingAnchor(rowID: inputs.row.id,
                frame: CGRect(x: 0, y: -100, width: 600, height: 550),
                viewport: CGRect(x: 0, y: 0, width: 600, height: 500)) else { return nil }
        let position = TranscriptReadingPosition()
        position.record(isFollowingLatest: false, anchor: saved, mountedStartRowID: nil)
        let surface = AppKitTranscriptContainer(presentation: TranscriptNativePresentation(readingPosition: position),
            readingPosition: position, readingScope: UUID())
        let store = RenderedMessageStore(renderer: { _ in [] })
        let presentations = TranscriptRowPresentations()
        defer {
            surface.tearDown()
            surface.removeFromSuperview()
            store.retire()
        }
        surface.isFollowingLatest = { false }
        surface.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        surface.isHidden = true
        surface.setRows([inputs], presentations: presentations, renderedMessages: store, reservedBottom: 0,
            environment: environment, environmentInputs: environmentInputs) { _ in EmptyView() }
        surface.setRows([], presentations: presentations, renderedMessages: store, reservedBottom: 0,
            environment: environment, environmentInputs: environmentInputs) { _ in EmptyView() }
        surface.captureReadingPosition()
        let removed = surface.restoringReadingAnchor == nil && position.anchor == saved
            && position.lastRestorationOutcome == .init(rowID: saved.rowID, outcome: .sourceRemoved)
        surface.setRows([inputs], presentations: presentations, renderedMessages: store, reservedBottom: 0,
            environment: environment, environmentInputs: environmentInputs) { _ in EmptyView() }
        surface.restoreSavedReadingPosition(position)
        parent.addSubview(surface)
        let deadline = ContinuousClock.now + .seconds(2)
        while surface.restoringReadingAnchor != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        surface.captureReadingPosition()
        let unavailable = surface.restoringReadingAnchor == nil && position.anchor == saved
            && position.lastRestorationOutcome == .init(rowID: saved.rowID, outcome: .renderUnavailable)
        surface.restoreSavedReadingPosition(position)
        let retry = surface.restoringReadingAnchor == saved && position.anchor == saved
        return (removed, unavailable, retry)
    }

    func readingPositionForBench() -> (rowID: String, offset: CGFloat, fraction: CGFloat,
                                      height: CGFloat, width: CGFloat, scale: CGFloat, reflowPending: Bool)? {
        guard let anchor = readingAnchor(in: documentViewport), let row = index?.row(for: anchor.rowID),
              let columnWidth, let environmentInputs else { return nil }
        return (anchor.rowID, anchor.rowOffset, anchor.rowFraction, row.maxY - row.minY,
                columnWidth, environmentInputs.interfaceScale, reflowAnchor != nil)
    }

    func hasReadingOwnerForBench(_ position: TranscriptReadingPosition) -> Bool { readingPosition === position }

    func readingStateForBench() -> [String: Any] {
        let viewport = documentViewport
        let anchor = readingAnchor(in: viewport)
        return ["rowID": anchor.map { $0.rowID as Any } ?? NSNull(),
            "offset": anchor.map { $0.rowOffset as Any } ?? NSNull(),
            "fraction": anchor.map { $0.rowFraction as Any } ?? NSNull(),
            "height": anchor.map { $0.rowHeight as Any } ?? NSNull(),
            "viewportFraction": anchor.map { $0.viewportFraction as Any } ?? NSNull(),
            "columnWidth": columnWidth.map { $0 as Any } ?? NSNull(),
            "scale": environmentInputs.map { $0.interfaceScale as Any } ?? NSNull(),
            "reflowPending": reflowAnchor != nil, "restorationPending": readingRestoration?.isPending == true,
            "restoringRowID": restoringReadingAnchor.map { $0.rowID as Any } ?? NSNull(),
            "restorationOutcome": readingPosition?.lastRestorationOutcome.map { $0.outcome.rawValue as Any } ?? NSNull(),
            "surfaceState": String(describing: presentation.activity.state),
            "viewportOrigin": viewport.minY, "viewportHeight": viewport.height,
            "viewportWidth": viewport.width, "documentHeight": transcriptDocument.bounds.height,
            "maximumOrigin": maximumOrigin, "following": isFollowingLatest(),
            "hostedRowIDs": rowHosts.keys.sorted(),
            "savedFollowing": readingPosition.map { $0.isFollowingLatest as Any } ?? NSNull(),
            "savedRowID": readingPosition?.anchor.map { $0.rowID as Any } ?? NSNull(),
            "savedOffset": readingPosition?.anchor.map { $0.rowOffset as Any } ?? NSNull(),
            "initialBottom": initialBottom, "geometryDirty": geometryDirty, "layoutReady": isLayoutReady]
    }

    #endif

    private var isLayoutReady: Bool {
        index != nil && !geometryDirty && committedContentRevision == contentRevision
            && committedViewportSize == contentView.bounds.size
    }

    func alignRow(_ id: String, anchor: UnitPoint?, animated: Bool, completion: @escaping () -> Void) {
        submit(.row(id, anchor), animated: animated, completion: completion)
    }

    func showLatest(animated: Bool) { submit(.latest, animated: animated, completion: {}) }

    private func submit(_ destination: Command.Destination, animated: Bool, completion: @escaping () -> Void) {
        cancelIntent()
        cancelReadingRestoration()
        initialBottom = false
        let minimumContentRevision: Int
        if case .row(let id, _) = destination, logicalRows[id] == nil {
            minimumContentRevision = contentRevision + 1
        } else {
            minimumContentRevision = contentRevision
        }
        command = Command(serial: intentSerial, destination: destination, animated: animated,
                          minimumContentRevision: minimumContentRevision, completion: completion)
        hostsDirty = true
        scheduleCommit()
    }

    @discardableResult
    private func executeCommand() -> Bool {
        guard let command, let index, let columnWidth, isLayoutReady, committedContentRevision >= command.minimumContentRevision,
              contentView.bounds.height > 0 else { return false }
        let destination: CGFloat
        switch command.destination {
        case .latest: destination = maximumOrigin
        case .row(let id, let anchor):
            guard let origin = index.origin(for: id, anchor: anchor, viewport: documentViewport) else {
                self.command = nil
                PerfBuild.count("native.commandTargetMissing")
                return false
            }
            guard rowHosts[id]?.hasMeasurement(for: columnWidth) == true else { return false }
            destination = origin
        }
        self.command = nil
        if command.animated, abs(destination - documentViewport.minY) > 1 {
            PerfBuild.count("anim.start")
            animation = ScrollAnimation(serial: command.serial, from: documentViewport.minY,
                                        destination: command.destination, start: CACurrentMediaTime())
            changePhase(.animating)
            markSampleDirty()
        } else {
            PerfBuild.count("write.command")
            scroll(to: destination)
        }
        command.completion()
        return true
    }

    private var documentViewport: CGRect { transcriptDocument.convert(contentView.bounds, from: contentView) }
    private var maximumOrigin: CGFloat {
        max(transcriptDocument.bounds.minY, transcriptDocument.bounds.maxY - documentViewport.height)
    }
    private var atBottom: Bool { maximumOrigin - documentViewport.minY <= 1 }
    private var isUserScrolling: Bool { phase == .tracking || phase == .interacting || phase == .decelerating }

    private func clipBounds(atDocumentY y: CGFloat) -> CGRect {
        var viewport = documentViewport
        viewport.origin.y = y
        return contentView.constrainBoundsRect(contentView.convert(viewport, from: transcriptDocument))
    }

    private func constrained(_ y: CGFloat) -> CGFloat {
        transcriptDocument.convert(clipBounds(atDocumentY: y), from: contentView).minY
    }

    private func scroll(to y: CGFloat) {
        let bounds = clipBounds(atDocumentY: y)
        guard abs(bounds.minY - contentView.bounds.minY) > 0.001 else {
            PerfBuild.count("write.equal")
            return
        }
        PerfBuild.count("write.program")
        let wasWritingGeometry = isWritingGeometry
        isWritingGeometry = true
        defer { isWritingGeometry = wasWritingGeometry }
        if isUserScrolling { userInputOrigin = bounds.minY }
        contentView.scroll(to: bounds.origin)
        reflectScrolledClipView(contentView)
        markSampleDirty()
    }

    private func cancelIntent() {
        reflowAnchor = nil
        hostsDirty = true
        intentSerial += 1
        command = nil
        if animation != nil { PerfBuild.count("anim.cancel") }
        animation = nil
        if phase == .animating { requestIdle() }
    }

    func haltScrolling() {
        PerfBuild.count("input.halt")
        cancelIntent()
        if ownsWheelGesture { wheelGesture = .draining }
        onEvent(.userCancelled)
        idleTimer?.invalidate()
        idleTimer = nil
        requestIdle()
    }

    func navigate(_ navigation: TranscriptScrollHalt.Navigation) {
        haltScrolling()
        initialBottom = false
        onNavigate(navigation)
        switch navigation {
        case .pageUp: scroll(to: documentViewport.minY - documentViewport.height * 0.9)
        case .pageDown: scroll(to: documentViewport.minY + documentViewport.height * 0.9)
        case .beginning: scroll(to: transcriptDocument.bounds.minY)
        case .end: showLatest(animated: false)
        }
    }

    override func pageUp(_ sender: Any?) { navigate(.pageUp) }
    override func pageDown(_ sender: Any?) { navigate(.pageDown) }
    override func scrollPageUp(_ sender: Any?) { navigate(.pageUp) }
    override func scrollPageDown(_ sender: Any?) { navigate(.pageDown) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { navigate(.beginning) }
    override func scrollToEndOfDocument(_ sender: Any?) { navigate(.end) }

    private func observe(_ event: NSEvent) -> NSEvent? {
        hitCache = nil
        if event.window === window, event.type == .leftMouseDown || event.type == .rightMouseDown {
            let point = transcriptDocument.convert(event.locationInWindow, from: nil)
            let inside = contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil))
            interactionRowID = inside ? index?.rowID(at: point.y) : nil
            hostsDirty = true
            markSampleDirty()
        }
        let wheel = event.type == .scrollWheel
        let startsGesture = wheel && (event.phase.contains(.began) || event.phase.contains(.mayBegin))
        let unphasedWheel = wheel && event.phase.isEmpty && event.momentumPhase.isEmpty
        let fresh = startsGesture || (unphasedWheel && (wheelGesture == .draining || !isUserScrolling))
        if startsGesture || unphasedWheel { wheelGesture = nil }
        if !wheel { wheelEventAxis = nil }
        defer {
            if wheel && (event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended)
                         || event.momentumPhase.contains(.cancelled)) {
                wheelGesture = nil
            }
        }
        let axis = wheel ? wheelAxis(for: event) : .unresolved
        if wheel {
            PerfBuild.count("wheel.monitor")
            if !unphasedWheel, wheelGesture == nil {
                switch axis {
                case .unresolved: break
                case .horizontal: wheelGesture = .horizontal
                case .vertical: wheelGesture = .vertical
                }
            }
        }
        guard event.window === window, !isHiddenOrHasHiddenAncestor else {
            wheelEventAxis = nil
            if wheel { PerfBuild.count("wheel.otherWindow") }
            return event
        }
        if event.type == .leftMouseUp, selectionTracking {
            selectionTracking = false
            if isUserScrolling { requestIdle() }
            return event
        }
        if event.type == .leftMouseDragged, selectionTracking {
            beginUserInput(.interacting, fresh: false)
            return event
        }
        let inside = contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil))
        if wheel {
            if inside, wheelGesture == .vertical { wheelGesture = .ownedVertical }
            let needsReset = wheelEventAxis == nil
            wheelEventAxis = axis
            if needsReset {
                DispatchQueue.main.async { [weak self] in self?.wheelEventAxis = nil }
            }
        }
        let ownedWheel = wheel && ownsWheelGesture && (!event.phase.isEmpty || !event.momentumPhase.isEmpty)
        if !inside && !ownedWheel {
            if wheel { PerfBuild.count("wheel.outside") }
            return event
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            selectionTracking = event.type == .leftMouseDown
            if isUserScrolling || animation != nil { haltScrolling() }
            return event
        }
        guard wheel else { return event }
        if NSApp.currentEvent?.timestamp != event.timestamp { PerfBuild.count("wheel.noCurrent") }
        let hasMomentum = !event.momentumPhase.isEmpty
        if fresh {
            PerfBuild.count("wheel.began")
            idleTimer?.invalidate()
            idleTimer = nil
        } else if wheelGesture == .draining {
            PerfBuild.count("wheel.dropDrain")
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                PerfBuild.count("wheel.drainEnd")
            }
            return nil
        }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            PerfBuild.count("wheel.ended")
            requestIdle()
        } else if wheelEventAxis == .horizontal {
            PerfBuild.count("wheel.horizontal")
            return event
        } else if hasMomentum {
            beginUserInput(.decelerating, fresh: false)
        } else if event.phase.contains(.mayBegin) {
            beginUserInput(.tracking, fresh: fresh)
        } else {
            beginUserInput(.interacting, fresh: fresh)
            if event.phase.isEmpty {
                idleTimer?.invalidate()
                let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        PerfBuild.count("input.legacyIdle")
                        self?.requestIdle()
                    }
                }
                idleTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        PerfBuild.count("wheel.pass")
        return event
    }

    private func beginUserInput(_ next: ScrollPhase, fresh: Bool) {
        if fresh || !isUserScrolling {
            PerfBuild.count("input.takeover")
            cancelIntent()
            cancelReadingRestoration()
            initialBottom = false
            userInputOrigin = contentView.bounds.minY
            lastUserBottom = nil
        }
        idlePending = false
        if fresh && phase == next {
            onEvent(.phase(next, atBottom: atBottom))
        } else {
            changePhase(next)
        }
    }

    @objc private func beginLiveScroll() {
        PerfBuild.count("input.liveBegin")
        if wheelGesture != .draining { beginUserInput(.interacting, fresh: false) }
    }

    @objc private func endLiveScroll() {
        PerfBuild.count("input.liveEnd")
        requestIdle()
    }

    @objc private func boundsChanged() {
        hitCache = nil
        hostsDirty = true
        PerfBuild.count(isWritingGeometry ? "bounds.program" : isUserScrolling ? "bounds.user" : "bounds.other")
        if !isWritingGeometry, isUserScrolling, let origin = userInputOrigin, abs(origin - contentView.bounds.minY) > 0.001 {
            reflowAnchor = nil
            userInputOrigin = contentView.bounds.minY
            if lastUserBottom != atBottom {
                lastUserBottom = atBottom
                onEvent(.userMoved(atBottom: atBottom))
            }
        }
        markSampleDirty()
    }

    private func changePhase(_ next: ScrollPhase) {
        guard phase != next else { return }
        phase = next
        halt.setScrollPhase(next)
        onEvent(.phase(next, atBottom: atBottom))
    }

    private func requestIdle() {
        PerfBuild.count("input.idleRequest")
        idlePending = true
        markSampleDirty()
    }

    private func markSampleDirty() {
        guard !isTornDown, !isSuspended else { return }
        samplePending = true
        guard window != nil else { return }
        if frameLink == nil {
            let link = displayLink(target: frameTarget, selector: #selector(TranscriptDisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.frameLink = link
        }
        frameLink?.isPaused = false
    }

    fileprivate func sample(_ link: CADisplayLink) {
        admissionsThisFrame = 0
        admissionElapsed = 0
        if hostsDirty || admissionPending {
            hostsDirty = true
            commitLayout()
        }
        if let animation, animation.serial == intentSerial {
            let progress = min(1, max(0, (CACurrentMediaTime() - animation.start) / 0.5))
            let eased = progress * progress * (3 - 2 * progress)
            let destination: CGFloat
            switch animation.destination {
            case .latest: destination = maximumOrigin
            case .row(let id, let anchor):
                guard let origin = index?.origin(for: id, anchor: anchor, viewport: documentViewport) else {
                    cancelIntent()
                    return
                }
                destination = constrained(origin)
            }
            scroll(to: animation.from + (destination - animation.from) * eased)
            if progress >= 1 {
                PerfBuild.count("anim.finish")
                self.animation = nil
                idlePending = true
            }
        }
        if samplePending {
            samplePending = false
            publishSample()
        }
        if idlePending, animation == nil {
            idlePending = false
            userInputOrigin = nil
            if !userHasMoved { onEvent(.userCancelled) }
            changePhase(.idle)
        }
        link.isPaused = !samplePending && animation == nil && !admissionPending && !hostsDirty
    }

    func captureReadingPosition() { saveReadingPosition() }

    private func saveReadingPosition() {
        guard presentation.activity.state == .mounted, restoringReadingAnchor == nil, index != nil else { return }
        guard readingRestoration?.permitsCapture != false else { return }
        let following = isFollowingLatest()
        readingPosition?.record(isFollowingLatest: following, anchor: following ? nil : readingAnchor(in: documentViewport),
            mountedStartRowID: nil)
    }

    private func publishSample() {
        let span = PerfBuild.span("native.publishSample"); defer { span.end() }
        guard let index else { return }
        let viewport = documentViewport
        saveReadingPosition()
        let visible = index.visibility(in: viewport)
        let geometry = TranscriptNativeGeometry(height: viewport.height, columnWidth: columnWidth.map { Int($0.rounded()) },
            isNearTop: viewport.minY - transcriptDocument.bounds.minY < viewport.height * 1.5, isAtBottom: atBottom,
            isFarFromLatest: index.latestEnd.map { TranscriptLayout.isFarFromLatest(
                latestEnd: $0, visibleBottom: viewport.maxY, viewportHeight: viewport.height) },
            isRunwayShort: visible.isRunwayShort)
        if geometry != lastGeometry {
            lastGeometry = geometry
            onEvent(.geometry(geometry))
        }
        let ids = visible.ids.filter { rowHosts[$0]?.view.alphaValue == 1 }
        #if RC_PERF_HARNESS
        if !ids.isEmpty, ids == visible.ids, let address = presentedAddressForBench {
            PerfHarness.shared.contentBecameReady(at: address, container: self)
        }
        #endif
        if ids != lastVisibleIDs {
            lastVisibleIDs = ids
            PerfBuild.count("transcriptVisibilityEmissions")
            onEvent(.visibility(ids))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        halt.attach(self)
        resume()
    }

    func resume() {
        guard !isTornDown, window != nil else { return }
        observeNativeLifecycle()
        isSuspended = false
        startReadingReadiness()
        hostsDirty = true
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .otherMouseDown, .otherMouseDragged, .otherMouseUp, .pressure
            ]) { [weak self] event in
                let passes = MainActor.assumeIsolated {
                    guard let self else { return true }
                    return self.observe(event) != nil
                }
                return passes ? event : nil
            }
        }
        scheduleCommit()
        markSampleDirty()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { suspend() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
        if !changedWindow.occlusionState.contains(.visible) { suspend() }
        else { resume() }
    }

    func suspend() {
        saveReadingPosition()
        readingReadinessTask?.cancel()
        readingReadinessTask = nil
        isSuspended = true
        onEvent(.userCancelled)
        selectionTracking = false
        wheelEventAxis = nil
        cancelIntent()
        wheelGesture = nil
        lastUserBottom = nil
        idlePending = false
        idleTimer?.invalidate()
        idleTimer = nil
        cancelPreparation()
        frameLink?.invalidate()
        frameLink = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        userInputOrigin = nil
        changePhase(.idle)
        halt.setScrollPhase(.idle)
    }

    func tearDown() {
        finishReadingRestoration(.detached)
        saveReadingPosition()
        presentation.activity.state = .retired
        presentation.actions.clear()
        presentation.visibility.setScrollPhase(.idle)
        readingPosition?.detach(self, scope: readingScope)
        isTornDown = true
        onEvent = { _ in }
        onNavigate = { _ in }
        suspend()
        for host in rowHosts.values { host.remove() }
        rowHosts.removeAll()
        for row in logicalRows.values { row.presentation.onPinChange = { _ in } }
        logicalRows.removeAll()
        pinnedRows.removeAll()
        rowContent = nil
        environment = nil
        renderedMessages = nil
        rowOrder.removeAll()
        dirtyHosts.removeAll()
        hitCache = nil
        index = nil
        transcriptDocument.container = nil
        endpoint.detach(self)
        halt.detach(self)
        NotificationCenter.default.removeObserver(self)
        observesNativeLifecycle = false
        onEvent = { _ in }
        onNavigate = { _ in }
        isFollowingLatest = { true }
    }

    func observesRenderedMessage(_ id: UUID, in store: ObjectIdentifier) -> Bool {
        renderStoreID == store && rowHosts.values.contains { $0.inputs.row.message?.id == id }
    }

    var renderStoreID: ObjectIdentifier? { renderedMessages.map(ObjectIdentifier.init) }

    func discardRetainedSurface() { tearDown() }

    func detachSurface() {
        finishReadingRestoration(.detached)
        let retainable = isLayoutReady && !rowHosts.isEmpty && rowHosts.count <= 96
            && restoringReadingAnchor == nil && reflowAnchor == nil && command == nil && animation == nil
            && pinnedRows.isEmpty && !selectionTracking && !isUserScrolling && !presentation.codeExport.isPresented
            && presentation.codeExport.failure == nil
            && rowHosts.values.allSatisfy { host in
                if case .content(.viewedMedia) = host.inputs.row.kind { return false }
                if case .content(.publishedVisual) = host.inputs.row.kind { return false }
                guard let message = host.inputs.row.message else { return true }
                guard message.attachments.isEmpty, let rendered = renderedMessages?[message.id] else { return false }
                return rendered.blocks.allSatisfy { block in
                    switch block.content {
                    case .images, .mermaid, .htmlVisual: false
                    default: true
                    }
                }
            }
            && logicalRows.values.allSatisfy { row in
                if case .content(let item) = row.inputs.row.kind {
                    return TranscriptSurfaceRetention.hasQuiescentContent(item, historyEdgeStatus: row.inputs.edgeStatus)
                }
                return true
            }
        suspend()
        NotificationCenter.default.removeObserver(self)
        observesNativeLifecycle = false
        readingPosition?.detach(self, scope: readingScope)
        presentation.actions.clear()
        onEvent = { _ in }
        onNavigate = { _ in }
        isFollowingLatest = { [follow = presentation.follow] in follow.isFollowingLatest }
        rowContent = nil
        lastGeometry = nil
        interactionRowID = nil
        lastVisibleIDs = nil
        if retainable, let readingPosition, let retention, retention.retain(self, for: readingPosition) {
            presentation.activity.state = .detached
            PerfBuild.count("native.surfaceRetained")
        } else {
            tearDown()
        }
    }
}

@MainActor
private final class TranscriptDisplayLinkTarget: NSObject {
    weak var container: AppKitTranscriptContainer?
    @objc func tick(_ link: CADisplayLink) { container?.sample(link) }
}

#if RC_PERF_HARNESS
private final class TranscriptHarnessClipView: NSClipView {
    override class var isCompatibleWithResponsiveScrolling: Bool {
        !PerfBuild.disabled.contains("responsiveScrolling")
    }
}
#endif

private final class AppKitTranscriptDocument: NSView {
    weak var container: AppKitTranscriptContainer?
    #if RC_PERF_HARNESS
    override class var isCompatibleWithResponsiveScrolling: Bool {
        !PerfBuild.disabled.contains("responsiveScrolling")
    }
    #endif

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if container?.routesCurrentWheelVertically == true,
           !isHidden, bounds.contains(convert(point, from: superview)) {
            PerfBuild.count("hit.document")
            return self
        }
        let documentPoint = convert(point, from: superview)
        guard !isHidden, bounds.contains(documentPoint) else { return nil }
        return container?.rowView(at: documentPoint) ?? self
    }
}

#endif
