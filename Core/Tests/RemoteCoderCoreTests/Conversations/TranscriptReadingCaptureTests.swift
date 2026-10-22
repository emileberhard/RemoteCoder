import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct TranscriptReadingCaptureTests {
    @Test func retainedRunwayUsesMeasuredViewportHeightAndLeavesUnavailableGeometryUnknown() {
        let capture = TranscriptReadingCapture()
        #expect(capture.runwayViewportCount(from: ["header", "retained"]) == nil)
        capture.setFrame(CGRect(x: 0, y: 0, width: 600, height: 28), rowID: "retained")
        #expect(capture.runwayViewportCount(from: ["header", "retained"]) == nil)
        capture.updateViewport(CGRect(x: 0, y: 2_240, width: 600, height: 1_190))
        #expect((capture.runwayViewportCount(from: ["header", "retained"]) ?? .infinity) < 2)
        capture.updateViewport(CGRect(x: 0, y: 2_240, width: 600, height: 700))
        #expect((capture.runwayViewportCount(from: ["header", "retained"]) ?? 0) > 2.5)
        capture.setFrame(CGRect(x: 0, y: 2_000, width: 600, height: 28), rowID: "later")
        #expect((capture.runwayViewportCount(from: ["header", "later", "retained"]) ?? .infinity) < 1)
        capture.retainRows([])
        #expect(capture.runwayViewportCount(from: ["header", "retained"]) == nil)
    }

    @Test func restorationWaitsForGeometryAndStopsIssuingRequestsOnceTheMeasuredPointArrives() throws {
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        var restoration = TranscriptReadingRestoration(anchor: saved, deadline: .now + .seconds(1))
        let row = CGRect(x: 0, y: 1_000, width: 200, height: 2_000)
        let unmeasured = restoration.update(row: row, viewport: .zero)
        #expect(unmeasured == nil)
        restoration.finish()
        #expect(restoration.isPending)
        var viewport = CGRect(x: 0, y: 0, width: 200, height: 500)
        let initialRequest = restoration.update(row: row, viewport: viewport)
        let alignment = try #require(initialRequest)
        #expect(abs(alignment.fraction - 0.24242424242424243) < 1e-9)
        for y in 1..<20 {
            viewport.origin.y = CGFloat(y)
            let repeated = restoration.update(row: row, viewport: viewport)
            #expect(repeated == nil)
            #expect(restoration.isPending)
        }
        let measured = CGRect(x: 0, y: 1_000, width: 200, height: 2_200)
        let correctedRequest = restoration.update(row: measured, viewport: viewport)
        let corrected = try #require(correctedRequest)
        #expect(abs(corrected.fraction - 0.23529411764705882) < 1e-9)
        viewport.origin.y = 1_400
        let arrived = restoration.update(row: measured, viewport: viewport)
        #expect(arrived == nil)
        #expect(!restoration.isPending)
        let afterCompletion = restoration.update(row: CGRect(x: 0, y: 1_000, width: 200, height: 4_000), viewport: viewport)
        #expect(afterCompletion == nil)
    }

    @Test func restorationIgnoresSubpointNoiseAndStopsRequestingWhenGeometryNeverSettles() throws {
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        var restoration = TranscriptReadingRestoration(anchor: saved, deadline: .now + .seconds(1))
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 500)
        #expect(restoration.update(row: CGRect(x: 0, y: 1_000, width: 200, height: 2_000), viewport: viewport) != nil)
        #expect(restoration.update(row: CGRect(x: 0, y: 1_000, width: 200, height: 2_000.4), viewport: viewport) == nil)
        var requests = 1
        for cycle in 0..<100 {
            let row = CGRect(x: 0, y: 1_000, width: 200, height: cycle.isMultiple(of: 2) ? 2_200 : 2_000)
            if restoration.update(row: row, viewport: viewport) != nil { requests += 1 }
        }
        #expect(requests == TranscriptReadingRestoration.maximumRequests)
        #expect(restoration.result == .init(rowID: "reading", outcome: .geometryUnsettled))
        #expect(!restoration.permitsCapture)

        var settling = TranscriptReadingRestoration(anchor: saved, deadline: .now + .seconds(1))
        for step in 0..<TranscriptReadingRestoration.maximumRequests {
            let row = CGRect(x: 0, y: 1_000, width: 200, height: 2_000 + CGFloat(step) * 20)
            #expect(settling.update(row: row, viewport: viewport) != nil)
        }
        let arrivedRow = CGRect(x: 0, y: 1_000, width: 200, height: 2_160)
        let arrivedViewport = CGRect(x: 0, y: 1_000 + saved.rowFraction * arrivedRow.height, width: 200, height: 500)
        #expect(settling.update(row: arrivedRow, viewport: arrivedViewport) == nil)
        #expect(settling.result == .init(rowID: "reading", outcome: .completed))
    }

    @Test func captureDoesNotOverwriteTheBookmarkWhileItsMeasuredIdentityRequestIsPending() throws {
        let position = TranscriptReadingPosition()
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        position.record(isFollowingLatest: false, anchor: saved, mountedStartRowID: "first")
        let capture = TranscriptReadingCapture()
        capture.attach(position, scope: UUID()) { .reading(mountedStartRowID: "first") }
        capture.beginRestoration(saved, now: .now, request: { _, _ in }, completed: { _ in })
        capture.setFrame(CGRect(x: 0, y: 0, width: 200, height: 2_000), rowID: "reading")
        capture.updateViewport(CGRect(x: 0, y: 50, width: 200, height: 500))
        capture.captureReadingPosition()
        #expect(position.anchor == saved)
        #expect(position.mountedStartRowID == "first")
        #expect(!position.isFollowingLatest)
        capture.detach()
    }

    @Test func removedSourceTerminatesRestorationAndKeepsTheKnownBookmarkUntilUserNavigation() throws {
        let (position, saved) = try bookmark()
        let source = TranscriptRowPresentations()
        source.prepareSource(snapshot(revision: 1, rows: ["reading", "other"]), readingPosition: position)
        let capture = TranscriptReadingCapture()
        let scope = UUID()
        var requests = 0
        capture.attach(position, scope: scope) { .reading(mountedStartRowID: "first") }
        capture.bindSource(source)
        capture.setFrame(CGRect(x: 0, y: 0, width: 200, height: 100), rowID: "other")
        capture.updateViewport(CGRect(x: 0, y: 0, width: 200, height: 500))
        capture.beginRestoration(saved, now: .now, request: { _, _ in requests += 1 }, completed: { _ in })
        source.prepareSource(snapshot(revision: 2, rows: ["other"]), readingPosition: position)
        capture.sourceMembershipChanged()
        #expect(!capture.isRestoring)
        #expect(position.lastRestorationOutcome == .init(rowID: "reading", outcome: .sourceRemoved))
        capture.setFrame(CGRect(x: 0, y: 0, width: 200, height: 2_000), rowID: "reading")
        position.capture(scope: scope)
        #expect(requests == 0)
        #expect(position.anchor == saved)
        capture.cancelRestoration()
        capture.setFrame(nil, rowID: "reading")
        position.capture(scope: scope)
        #expect(position.anchor?.rowID == "other")
        capture.detach()
    }

    @Test func permanentlyUnavailableRenderEndsAtTheReadinessBoundWithoutInventingAReadingPoint() throws {
        let (position, saved) = try bookmark()
        let source = TranscriptRowPresentations()
        source.prepareSource(snapshot(revision: 1, rows: ["reading"]), readingPosition: position)
        let capture = TranscriptReadingCapture()
        let scope = UUID()
        let started = ContinuousClock.now
        var requests = 0
        capture.attach(position, scope: scope) { .reading(mountedStartRowID: "first") }
        capture.bindSource(source)
        capture.beginRestoration(saved, now: started, request: { _, _ in requests += 1 }, completed: { _ in })
        capture.finishRestoration()
        capture.expireRestoration(at: started + .milliseconds(999))
        #expect(capture.isRestoring)
        capture.expireRestoration(at: started + TranscriptReadingRestoration.renderReadinessTimeout)
        #expect(!capture.isRestoring)
        #expect(position.lastRestorationOutcome == .init(rowID: "reading", outcome: .renderUnavailable))
        capture.setFrame(CGRect(x: 0, y: 0, width: 200, height: 2_000), rowID: "reading")
        capture.updateViewport(CGRect(x: 0, y: 50, width: 200, height: 500))
        position.capture(scope: scope)
        #expect(requests == 0)
        #expect(position.anchor == saved)
        #expect(position.mountedStartRowID == "first")
        capture.detach()
    }

    @Test func detachEndsAnUnrequestedRestorationAndCancelsItsLaterReadinessResult() throws {
        let (position, saved) = try bookmark()
        let capture = TranscriptReadingCapture()
        var outcomes: [TranscriptReadingRestoration.Result] = []
        capture.attach(position, scope: UUID()) { .reading(mountedStartRowID: "first") }
        capture.beginRestoration(saved, now: .now, request: { _, _ in }, completed: { outcomes.append($0) })
        capture.detach()
        capture.expireRestoration(at: .now + .seconds(2))
        #expect(!capture.isRestoring)
        #expect(outcomes == [.init(rowID: "reading", outcome: .detached)])
        #expect(position.anchor == saved)
    }

    @Test func aDeliberateRetryAfterUnavailableRenderingCanRestoreTheSameKnownBookmark() throws {
        let (position, saved) = try bookmark()
        let capture = TranscriptReadingCapture()
        let scope = UUID()
        let started = ContinuousClock.now
        var requests = 0
        capture.attach(position, scope: scope) { .reading(mountedStartRowID: "first") }
        capture.beginRestoration(saved, now: started, request: { _, _ in requests += 1 }, completed: { _ in })
        capture.expireRestoration(at: started + .seconds(1))
        capture.setFrame(CGRect(x: 0, y: 0, width: 200, height: 2_000), rowID: "reading")
        capture.updateViewport(CGRect(x: 0, y: 50, width: 200, height: 500))
        #expect(requests == 0)
        capture.beginRestoration(saved, now: .now, request: { _, _ in requests += 1 }, completed: { _ in })
        #expect(requests == 1)
        capture.updateViewport(CGRect(x: 0, y: 363.6363636363636, width: 200, height: 500))
        #expect(!capture.isRestoring)
        #expect(position.lastRestorationOutcome == .init(rowID: "reading", outcome: .completed))
        position.capture(scope: scope)
        #expect(position.anchor?.rowID == "reading")
        capture.detach()
    }

    private func bookmark() throws -> (TranscriptReadingPosition, TranscriptReadingAnchor) {
        let position = TranscriptReadingPosition()
        let anchor = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        position.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: "first")
        return (position, anchor)
    }

    private func snapshot(revision: UInt64, rows: Set<String>) -> ConversationSnapshot {
        ConversationSnapshot(conversationID: UUID(), ownerID: UUID(), threadID: "reading", revision: revision,
            messages: [], timelines: [], items: [], lastTurnCompletedAt: nil, presentationRows: TranscriptPresentationRows(rowIDs: rows))
    }

    @Test func readingTargetsUseTheVisibleViewportRatherThanTheWholeScreen() throws {
        let viewport = CGRect(x: 0, y: 62, width: 370, height: 678)
        let top = try #require(TranscriptReadingAnchor(rowID: "command", frame: CGRect(x: 16, y: 62, width: 338, height: 50), viewport: viewport))
        #expect(top.identityAlignment == 0)
        let middle = try #require(TranscriptReadingAnchor(rowID: "command", frame: CGRect(x: 16, y: 376, width: 338, height: 50), viewport: viewport))
        #expect(middle.identityAlignment == 0.5)
        #expect(TranscriptReadingAnchor(rowID: "gone", frame: CGRect(x: 16, y: -100, width: 338, height: 50), viewport: viewport) == nil)
        #expect(TranscriptReadingAnchor(rowID: "unmeasured", frame: .zero, viewport: viewport) == nil)
    }

    @Test func aRowStraddlingTheViewportEdgeIsAReadingTargetAtItsCurrentOffset() throws {
        let viewport = CGRect(x: 0, y: 62, width: 370, height: 678)
        for frame in [CGRect(x: 16, y: -238, width: 338, height: 500),
            CGRect(x: 16, y: 500, width: 338, height: 400), CGRect(x: 16, y: -300, width: 338, height: 900),
            CGRect(x: 16, y: 374, width: 338, height: 900)] {
            let reading = try #require(TranscriptReadingAnchor(rowID: "reply", frame: frame, viewport: viewport))
            let alignment = try #require(reading.identityAlignment)
            #expect(abs(frame.minY + alignment * frame.height - viewport.minY - alignment * viewport.height) < 1e-9)
        }
        let nearlyViewportTall = try #require(TranscriptReadingAnchor(rowID: "reply",
            frame: CGRect(x: 16, y: -300, width: 338, height: 700), viewport: viewport))
        #expect(nearlyViewportTall.identityAlignment == nil)
    }

    @Test func theReadingTargetIsTheRowWithTheSmallestRepresentableAnchor() throws {
        let capture = TranscriptReadingCapture()
        capture.updateViewport(CGRect(x: 0, y: 0, width: 370, height: 600))
        for (id, frame) in ["above": CGRect(x: 16, y: -200, width: 338, height: 450),
            "whole": CGRect(x: 16, y: 100, width: 338, height: 200), "below": CGRect(x: 16, y: 500, width: 338, height: 300)] {
            capture.setFrame(frame, rowID: id)
        }
        #expect(capture.readingTarget()?.rowID == "whole")
        capture.retainRows([])
        for (id, frame) in ["upper": CGRect(x: 16, y: -600, width: 338, height: 1_000),
            "lower": CGRect(x: 16, y: 412, width: 338, height: 1_000), "gone": CGRect(x: 16, y: -1_700, width: 338, height: 1_000)] {
            capture.setFrame(frame, rowID: id)
        }
        #expect(capture.readingTarget()?.rowID == "lower")
        capture.retainRows([])
        capture.setFrame(CGRect(x: 16, y: 700, width: 338, height: 50), rowID: "gone")
        #expect(capture.readingTarget() == nil)
    }

    @Test func viewportTicksDoNotCaptureButASwitchDuringScrollingCapturesTheDepartingViewport() throws {
        let position = TranscriptReadingPosition()
        let capture = TranscriptReadingCapture()
        let scope = UUID()
        var modeReads = 0
        capture.attach(position, scope: scope) {
            modeReads += 1
            return .reading(mountedStartRowID: "loaded-floor")
        }
        for index in 0..<600 {
            capture.setFrame(CGRect(x: 0, y: index * 20, width: 600, height: 20), rowID: "reading-\(index)")
        }
        capture.updateViewport(CGRect(x: 0, y: 5, width: 600, height: 100))
        position.capture(scope: scope)
        let initial = try #require(position.anchor)
        #expect(initial.rowID == "reading-0")
        #expect(modeReads == 1)
        for index in 60..<80 {
            capture.updateViewport(CGRect(x: 0, y: index * 20 + 5, width: 600, height: 100))
        }
        #expect(modeReads == 1)
        #expect(position.anchor == initial)
        position.capture(scope: scope)
        #expect(modeReads == 2)
        #expect(position.anchor?.rowID == "reading-79")
        #expect(position.anchor?.rowOffset == 5)
        #expect(position.mountedStartRowID == "loaded-floor")
        #expect(!position.isFollowingLatest)
    }

    @Test func removingMountedRowsPrunesTheirFramesAndDetachFlushesTheRemainingPoint() throws {
        let position = TranscriptReadingPosition()
        let capture = TranscriptReadingCapture()
        let scope = UUID()
        capture.attach(position, scope: scope) { .reading(mountedStartRowID: nil) }
        capture.setFrame(CGRect(x: 0, y: 0, width: 600, height: 20), rowID: "removed")
        capture.setFrame(CGRect(x: 0, y: 20, width: 600, height: 20), rowID: "retained")
        capture.updateViewport(CGRect(x: 0, y: 0, width: 600, height: 100))
        capture.retainRows(["retained"])
        capture.detach()
        #expect(position.anchor?.rowID == "retained")
        let saved = try #require(position.anchor)
        capture.updateViewport(CGRect(x: 0, y: 25, width: 600, height: 100))
        position.capture(scope: scope)
        #expect(position.anchor == saved)
    }
}
