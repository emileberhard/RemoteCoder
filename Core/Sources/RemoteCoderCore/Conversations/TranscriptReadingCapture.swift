import CoreGraphics
import Foundation

@MainActor
final class TranscriptReadingCapture: TranscriptReadingPositionCapturing {
    enum Mode {
        case latest
        case reading(mountedStartRowID: String?)
    }

    private var frames: [String: CGRect] = [:]
    private var viewport = CGRect.zero
    private weak var position: TranscriptReadingPosition?
    private var scope: UUID?
    private var mode: (@MainActor () -> Mode)?
    private weak var source: TranscriptRowPresentations?
    private var restoration: TranscriptReadingRestoration?
    private var readinessTask: Task<Void, Never>?
    private var request: (@MainActor (String, TranscriptReadingAnchor.Alignment) -> Void)?
    private var completed: (@MainActor (TranscriptReadingRestoration.Result) -> Void)?

    var isRestoring: Bool { restoration?.isPending == true }

    isolated deinit { readinessTask?.cancel() }

    func bindSource(_ source: TranscriptRowPresentations) {
        self.source = source
        sourceMembershipChanged()
    }

    func beginRestoration(_ anchor: TranscriptReadingAnchor, now: ContinuousClock.Instant,
                          request: @escaping @MainActor (String, TranscriptReadingAnchor.Alignment) -> Void,
                          completed: @escaping @MainActor (TranscriptReadingRestoration.Result) -> Void) {
        readinessTask?.cancel()
        let deadline = now + TranscriptReadingRestoration.renderReadinessTimeout
        restoration = TranscriptReadingRestoration(anchor: anchor, deadline: deadline)
        self.request = request
        self.completed = completed
        sourceMembershipChanged()
        resolveRestoration()
        guard isRestoring else { return }
        readinessTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: ContinuousClock()) } catch { return }
            guard !Task.isCancelled, let self, self.restoration?.deadline == deadline else { return }
            self.expireRestoration(at: .now)
        }
    }

    func sourceMembershipChanged() {
        guard var pending = restoration, pending.isPending else { return }
        pending.sourceChanged(containsTarget: source?.sourceContains(pending.anchor.rowID))
        restoration = pending
        publishOutcome(pending)
    }

    func expireRestoration(at now: ContinuousClock.Instant) {
        guard var pending = restoration, pending.isPending else { return }
        pending.expire(at: now)
        restoration = pending
        publishOutcome(pending)
    }

    func finishRestoration() {
        guard var pending = restoration, pending.isPending else { return }
        pending.finish()
        restoration = pending
        publishOutcome(pending)
    }

    func cancelRestoration() {
        terminateRestoration(.cancelled)
        readinessTask?.cancel()
        readinessTask = nil
        restoration = nil
        request = nil
        completed = nil
        source = nil
    }

    func attach(_ position: TranscriptReadingPosition, scope: UUID, mode: @escaping @MainActor () -> Mode) {
        if let scope = self.scope { self.position?.detach(self, scope: scope) }
        self.position = position
        self.scope = scope
        self.mode = mode
        position.attach(self, scope: scope)
    }

    func detach() {
        terminateRestoration(.detached)
        captureReadingPosition()
        if let scope { position?.detach(self, scope: scope) }
        position = nil
        scope = nil
        mode = nil
        readinessTask?.cancel()
        readinessTask = nil
        request = nil
        completed = nil
        source = nil
    }

    func updateViewport(_ viewport: CGRect) {
        self.viewport = viewport
        resolveRestoration()
    }
    func setFrame(_ frame: CGRect?, rowID: String) {
        frames[rowID] = frame
        if restoration?.anchor.rowID == rowID { resolveRestoration() }
    }
    func retainRows(_ ids: Set<String>) { frames = frames.filter { ids.contains($0.key) } }

    func runwayViewportCount(from rowIDs: some Sequence<String>) -> CGFloat? {
        guard viewport.height > 0 else { return nil }
        for rowID in rowIDs {
            if let frame = frames[rowID], frame.height > 0 {
                return (viewport.minY - frame.minY) / viewport.height
            }
        }
        return nil
    }

    private func geometry(for rowID: String) -> (row: CGRect, viewport: CGRect)? {
        frames[rowID].map { ($0, viewport) }
    }

    func captureReadingPosition() {
        guard let position, let mode else { return }
        if restoration?.permitsCapture == false { return }
        switch mode() {
        case .latest:
            position.record(isFollowingLatest: true, anchor: nil, mountedStartRowID: nil)
        case .reading(let start):
            let selection = readingSelection()
            position.record(isFollowingLatest: false, anchor: selection.steady ?? selection.first, mountedStartRowID: start)
        }
    }

    func readingTarget() -> TranscriptReadingAnchor? { readingSelection().steady }

    private func resolveRestoration() {
        guard var pending = restoration, pending.isPending, let geometry = geometry(for: pending.anchor.rowID) else { return }
        let alignment = pending.update(row: geometry.row, viewport: geometry.viewport)
        restoration = pending
        publishOutcome(pending)
        if let alignment { request?(pending.anchor.rowID, alignment) }
    }

    private func terminateRestoration(_ outcome: TranscriptReadingRestoration.Outcome) {
        guard var pending = restoration, pending.isPending else { return }
        pending.terminate(outcome)
        restoration = pending
        publishOutcome(pending)
    }

    private func publishOutcome(_ restoration: TranscriptReadingRestoration) {
        guard let result = restoration.result else { return }
        readinessTask?.cancel()
        readinessTask = nil
        position?.recordRestorationOutcome(result)
        completed?(result)
    }

    private func readingSelection() -> (steady: TranscriptReadingAnchor?, first: TranscriptReadingAnchor?) {
        var steady: TranscriptReadingAnchor?
        var first: (anchor: TranscriptReadingAnchor, minY: CGFloat)?
        for (id, frame) in frames {
            guard let candidate = TranscriptReadingAnchor(rowID: id, frame: frame, viewport: viewport) else { continue }
            if first.map({ (frame.minY, id) < ($0.minY, $0.anchor.rowID) }) ?? true {
                first = (candidate, frame.minY)
            }
            if let alignment = candidate.identityAlignment,
               steady.map({ (abs(alignment), id) < (abs($0.alignment.fraction), $0.rowID) }) ?? true {
                steady = candidate
            }
        }
        return (steady, first?.anchor)
    }
}
