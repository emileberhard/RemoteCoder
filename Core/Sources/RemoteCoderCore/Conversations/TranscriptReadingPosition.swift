import CoreGraphics
import Foundation

struct TranscriptReadingLayout: Equatable, Sendable {
    let columnWidth: CGFloat
    let interfaceScale: CGFloat
    let dynamicTypeSize: String
    let localeIdentifier: String
    let isRightToLeft: Bool
}

struct TranscriptReadingAnchor: Equatable, Sendable {
    struct Alignment: Equatable, Sendable {
        let fraction: CGFloat
        let isClamped: Bool
    }

    private static let maximumAlignment: CGFloat = 2
    let rowID: String
    let rowOffset: CGFloat
    let rowFraction: CGFloat
    let viewportFraction: CGFloat
    let rowHeight: CGFloat
    let viewportHeight: CGFloat
    let layout: TranscriptReadingLayout?

    init?(rowID: String, frame: CGRect, viewport: CGRect, layout: TranscriptReadingLayout? = nil) {
        guard frame.minY.isFinite, frame.maxY.isFinite, frame.height > 0,
              viewport.minY.isFinite, viewport.maxY.isFinite, viewport.height > 0,
              frame.intersects(viewport) else { return nil }
        let point = max(frame.minY, viewport.minY)
        self.rowID = rowID
        self.layout = layout
        rowOffset = point - frame.minY
        rowFraction = rowOffset / frame.height
        viewportFraction = (point - viewport.minY) / viewport.height
        rowHeight = frame.height
        viewportHeight = viewport.height
    }

    func origin(rowMinY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        rowMinY + rowOffset - viewportFraction * viewportHeight
    }

    func matchesDisplayedPoint(_ current: Self?) -> Bool {
        guard let current else { return false }
        return rowID == current.rowID && rowOffset == current.rowOffset
            && viewportFraction == current.viewportFraction && layout == current.layout
    }

    func restoredOrigin(in row: CGRect, viewport: CGRect, layout: TranscriptReadingLayout) -> CGFloat {
        let reflows = self.layout.map { $0 != layout } ?? false
        let offset = reflows || rowOffset >= row.height ? rowFraction * row.height : rowOffset
        return row.minY + offset - viewportFraction * viewport.height
    }

    var identityAlignment: CGFloat? {
        let alignment = alignment
        guard abs(viewportHeight - rowHeight) > 0.5, !alignment.isClamped else { return nil }
        return alignment.fraction
    }

    var alignment: Alignment {
        Self.alignment(rowOffset: rowOffset, viewportFraction: viewportFraction,
                       rowHeight: rowHeight, viewportHeight: viewportHeight)
    }

    func restorationAlignment(rowHeight: CGFloat, viewportHeight: CGFloat) -> Alignment? {
        guard rowHeight.isFinite, rowHeight > 0, viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        let offset = min(rowHeight, max(0, rowFraction * rowHeight))
        return Self.alignment(rowOffset: offset, viewportFraction: viewportFraction,
                              rowHeight: rowHeight, viewportHeight: viewportHeight)
    }

    private static func alignment(rowOffset: CGFloat, viewportFraction: CGFloat,
                                  rowHeight: CGFloat, viewportHeight: CGFloat) -> Alignment {
        let space = viewportHeight - rowHeight
        let displacement = viewportFraction * viewportHeight - rowOffset
        guard space != 0 else { return Alignment(fraction: 0, isClamped: displacement != 0) }
        let required = displacement / space
        let fraction = min(Self.maximumAlignment, max(-Self.maximumAlignment, required))
        return Alignment(fraction: fraction, isClamped: fraction != required)
    }
}

struct TranscriptReadingRestoration {
    enum Outcome: String, Equatable, Sendable {
        case completed, sourceRemoved, renderUnavailable, geometryUnsettled, detached, cancelled

        var preservesBookmark: Bool {
            switch self {
            case .sourceRemoved, .renderUnavailable, .geometryUnsettled, .detached: true
            case .completed, .cancelled: false
            }
        }
    }

    struct Result: Equatable, Sendable {
        let rowID: String
        let outcome: Outcome
    }

    static let renderReadinessTimeout: Duration = .seconds(1)
    static let maximumRequests = 8
    private static let geometryTolerance: CGFloat = 1
    private struct Geometry {
        let rowHeight: CGFloat
        let viewportHeight: CGFloat

        func matches(_ other: Self) -> Bool {
            abs(rowHeight - other.rowHeight) <= TranscriptReadingRestoration.geometryTolerance
                && abs(viewportHeight - other.viewportHeight) <= TranscriptReadingRestoration.geometryTolerance
        }
    }

    let anchor: TranscriptReadingAnchor
    let deadline: ContinuousClock.Instant
    private var requestedGeometry: Geometry?
    private var requests = 0
    private(set) var outcome: Outcome?

    var isPending: Bool { outcome == nil }
    var pendingAnchor: TranscriptReadingAnchor? { isPending ? anchor : nil }
    var permitsCapture: Bool { !isPending && outcome?.preservesBookmark != true }
    var result: Result? { outcome.map { Result(rowID: anchor.rowID, outcome: $0) } }

    init(anchor: TranscriptReadingAnchor, deadline: ContinuousClock.Instant) {
        self.anchor = anchor
        self.deadline = deadline
    }

    mutating func update(row: CGRect, viewport: CGRect) -> TranscriptReadingAnchor.Alignment? {
        guard isPending, row.minY.isFinite, viewport.minY.isFinite,
              let alignment = anchor.restorationAlignment(rowHeight: row.height, viewportHeight: viewport.height) else { return nil }
        let destination = row.minY + alignment.fraction * (row.height - viewport.height)
        if abs(destination - viewport.minY) <= 1 {
            terminate(.completed)
            return nil
        }
        let geometry = Geometry(rowHeight: row.height, viewportHeight: viewport.height)
        if requestedGeometry?.matches(geometry) == true { return nil }
        guard requests < Self.maximumRequests else {
            terminate(.geometryUnsettled)
            return nil
        }
        requests += 1
        requestedGeometry = geometry
        return alignment
    }

    mutating func finish() {
        if requestedGeometry != nil { terminate(.completed) }
    }

    mutating func expire(at now: ContinuousClock.Instant) {
        if now >= deadline { terminate(.renderUnavailable) }
    }

    mutating func sourceChanged(containsTarget: Bool?) {
        if containsTarget == false { terminate(.sourceRemoved) }
    }

    mutating func terminate(_ outcome: Outcome) {
        if isPending { self.outcome = outcome }
    }
}

@MainActor
protocol TranscriptReadingPositionCapturing: AnyObject {
    func captureReadingPosition()
}

@MainActor
final class TranscriptReadingPosition {
    private struct WeakOwner {
        weak var value: (any TranscriptReadingPositionCapturing)?
    }
    private var owners: [UUID: WeakOwner] = [:]
    private weak var retention: TranscriptSurfaceRetention?
    private var sourceRevision: UInt64?
    private(set) var isFollowingLatest = true
    private(set) var anchor: TranscriptReadingAnchor?
    private(set) var mountedStartRowID: String?
    private(set) var lastRestorationOutcome: TranscriptReadingRestoration.Result?

    nonisolated init() {}

    isolated deinit {
        retention?.invalidate(self)
    }

    func addSurfaceRetention(_ retention: TranscriptSurfaceRetention) {
        precondition(self.retention == nil || self.retention === retention)
        self.retention = retention
    }

    func releaseSurfaceRetention(_ retention: TranscriptSurfaceRetention) {
        if self.retention === retention { self.retention = nil }
    }

    func preparePresentationChange() { retention?.invalidate(self) }

    func prepareSource(revision: UInt64) {
        guard sourceRevision.map({ revision > $0 }) ?? true else { return }
        if sourceRevision != nil {
            retention?.invalidate(self)
        }
        sourceRevision = revision
    }

    func attach(_ owner: any TranscriptReadingPositionCapturing, scope: UUID) {
        owners = owners.filter { $0.value.value != nil }
        owners[scope] = WeakOwner(value: owner)
    }

    func detach(_ owner: any TranscriptReadingPositionCapturing, scope: UUID) {
        if owners[scope]?.value === owner { owners.removeValue(forKey: scope) }
    }

    func capture(scope: UUID) {
        owners[scope]?.value?.captureReadingPosition()
    }

    func recordRestorationOutcome(_ result: TranscriptReadingRestoration.Result) {
        lastRestorationOutcome = result
    }

    func record(isFollowingLatest: Bool, anchor: TranscriptReadingAnchor?, mountedStartRowID: String?) {
        self.isFollowingLatest = isFollowingLatest
        if isFollowingLatest {
            self.anchor = nil
            self.mountedStartRowID = nil
        } else if let anchor {
            self.anchor = anchor
            self.mountedStartRowID = mountedStartRowID
        }
    }
}
