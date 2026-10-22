import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct TranscriptReadingPositionTests: ConversationHistoryFixtures {
    @Test func unavailableNativeTargetsClearThePendingAnchorAndPreserveTheBookmarkForAnExplicitRetry() throws {
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        let deadline = ContinuousClock.now + TranscriptReadingRestoration.renderReadinessTimeout
        for outcome in [TranscriptReadingRestoration.Outcome.sourceRemoved, .renderUnavailable, .detached] {
            var restoration = TranscriptReadingRestoration(anchor: saved, deadline: deadline)
            restoration.sourceChanged(containsTarget: nil)
            #expect(restoration.pendingAnchor == saved)
            #expect(!restoration.permitsCapture)
            switch outcome {
            case .sourceRemoved: restoration.sourceChanged(containsTarget: false)
            case .renderUnavailable:
                restoration.expire(at: deadline - .milliseconds(1))
                #expect(restoration.pendingAnchor == saved)
                restoration.expire(at: deadline)
            default: restoration.terminate(outcome)
            }
            #expect(restoration.pendingAnchor == nil)
            #expect(restoration.result == .init(rowID: saved.rowID, outcome: outcome))
            #expect(restoration.anchor == saved)
            #expect(!restoration.permitsCapture)
            var retry = TranscriptReadingRestoration(anchor: restoration.anchor, deadline: deadline + .seconds(1))
            retry.sourceChanged(containsTarget: true)
            #expect(retry.pendingAnchor == saved)
            retry.terminate(.completed)
            #expect(retry.pendingAnchor == nil)
            #expect(retry.permitsCapture)
        }
    }

    @Test func aCachedReturnRestoresTheCanonicalRowAndItsExactOffset() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let original = await registry.session(threadID: "reading")
        let snapshot = await original.merge(.fixture(threadID: "reading", wire: entries([.agentMessage(id: "answer", text: "Long reply")], turnID: "turn")))
        let rowID = try #require(snapshot.items.first?.id)
        let anchor = try #require(TranscriptReadingAnchor(rowID: rowID,
            frame: CGRect(x: 0, y: 1_000, width: 600, height: 800),
            viewport: CGRect(x: 0, y: 1_123.5, width: 600, height: 500)))
        original.readingPosition.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: "earlier-row")
        var cache = RecentConversationCache(capacity: 8)
        cache.record(snapshot, session: original)
        _ = await registry.session(threadID: "away")
        let restored = try #require(cache.presentation(threadID: "reading")?.session?.readingPosition)
        let saved = try #require(restored.anchor)
        #expect(!restored.isFollowingLatest)
        #expect(saved.rowID == rowID)
        #expect(saved.origin(rowMinY: -2_000, viewportHeight: 500) == -1_876.5)
        #expect(saved.alignment.fraction == 0.4116666666666667)
        #expect(restored.mountedStartRowID == "earlier-row")
        #expect(await registry.session(threadID: "reading").readingPosition === restored)
        await registry.invalidate(threadID: "reading")
        await registry.invalidate(threadID: "away")
    }

    @Test func reconstructionUsesFractionAfterReflowAndAbsoluteOffsetForUnchangedLayout() throws {
        let before = TranscriptReadingLayout(columnWidth: 500, interfaceScale: 1.1, dynamicTypeSize: "large",
            localeIdentifier: "en", isRightToLeft: false)
        let after = TranscriptReadingLayout(columnWidth: 900, interfaceScale: 1, dynamicTypeSize: "large",
            localeIdentifier: "en", isRightToLeft: false)
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: 1_000, width: 500, height: 1_000),
            viewport: CGRect(x: 0, y: 1_800, width: 500, height: 100), layout: before))
        let measured = CGRect(x: 0, y: 3_000, width: 900, height: 500)
        var viewport = CGRect(x: 0, y: 0, width: 900, height: 100)
        viewport.origin.y = saved.restoredOrigin(in: measured, viewport: viewport, layout: after)
        #expect(viewport.minY == 3_400)
        #expect(measured.contains(CGPoint(x: 1, y: viewport.minY)))
        let committed = try #require(TranscriptReadingAnchor(rowID: "reading", frame: measured,
            viewport: viewport, layout: after))
        #expect(committed.rowFraction == saved.rowFraction)
        viewport.origin.y = committed.restoredOrigin(in: measured, viewport: viewport, layout: after)
        #expect(viewport.minY == 3_400)
        #expect(saved.restoredOrigin(in: CGRect(x: 0, y: 3_000, width: 500, height: 1_100),
            viewport: viewport, layout: before) == 3_800)
    }

    @Test func aCachedWideSurfaceRestoresTheLatestNarrowWindowBookmarkEvenAtTheSameAbsoluteOffset() throws {
        let wide = TranscriptReadingLayout(columnWidth: 900, interfaceScale: 1, dynamicTypeSize: "large",
            localeIdentifier: "en", isRightToLeft: false)
        let narrow = TranscriptReadingLayout(columnWidth: 400, interfaceScale: 1, dynamicTypeSize: "large",
            localeIdentifier: "en", isRightToLeft: false)
        let wideRow = CGRect(x: 0, y: 1_000, width: 900, height: 500)
        let viewport = CGRect(x: 0, y: 1_100, width: 900, height: 300)
        let displayed = try #require(TranscriptReadingAnchor(rowID: "reading", frame: wideRow,
            viewport: viewport, layout: wide))
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: 1_000, width: 400, height: 1_000),
            viewport: CGRect(x: 0, y: 1_100, width: 400, height: 300), layout: narrow))
        #expect(saved.rowID == displayed.rowID)
        #expect(saved.rowOffset == displayed.rowOffset)
        #expect(saved.viewportFraction == displayed.viewportFraction)
        #expect(!saved.matchesDisplayedPoint(displayed))
        #expect(displayed.matchesDisplayedPoint(displayed))
        #expect(!saved.matchesDisplayedPoint(nil))
        let restored = saved.restoredOrigin(in: wideRow, viewport: viewport, layout: wide)
        #expect(restored == 1_050)
        let captured = try #require(TranscriptReadingAnchor(rowID: "reading", frame: wideRow,
            viewport: CGRect(x: 0, y: restored, width: 900, height: 300), layout: wide))
        #expect(captured.rowFraction == saved.rowFraction)
        #expect(captured.rowOffset == 50)
        #expect(!saved.matchesDisplayedPoint(captured))
        #expect(captured.matchesDisplayedPoint(captured))
    }

    @Test func identityRestorationResolvesTheSavedPointInsideTheCurrentlyMeasuredRow() throws {
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        #expect(saved.alignment.fraction == 2)
        let row = CGRect(x: 0, y: 1_000, width: 200, height: 2_000)
        let viewportHeight: CGFloat = 500
        let alignment = try #require(saved.restorationAlignment(rowHeight: row.height, viewportHeight: viewportHeight))
        let restored = row.minY + alignment.fraction * (row.height - viewportHeight)
        #expect(restored >= row.minY && restored < row.maxY)
        #expect(abs(restored - 1_363.6363636363637) < 1e-9)
        #expect(!alignment.isClamped)
    }

    @Test func identityRestorationClampsAgainstCurrentGeometryWithoutEscapingItsRow() throws {
        let saved = try #require(TranscriptReadingAnchor(rowID: "reading",
            frame: CGRect(x: 0, y: -100, width: 600, height: 550),
            viewport: CGRect(x: 0, y: 0, width: 600, height: 500)))
        for (height, clamped) in [(CGFloat(450), false), (500, true), (549, true), (550, false), (2_000, false)] {
            let alignment = try #require(saved.restorationAlignment(rowHeight: height, viewportHeight: 500))
            let offset = alignment.fraction * (height - 500)
            #expect(offset >= 0 && offset < height)
            #expect(abs(alignment.fraction) <= 2)
            #expect(alignment.isClamped == clamped)
        }
        #expect(saved.restorationAlignment(rowHeight: 0, viewportHeight: 500) == nil)
        #expect(saved.restorationAlignment(rowHeight: 2_000, viewportHeight: 0) == nil)
    }

    @Test func aPresentationEvictionLeavesTheSessionBookmarkAvailableForTheFirstContentMount() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let original = await registry.session(threadID: "reading")
        let snapshot = await original.merge(.fixture(threadID: "reading", wire: entries([
            .agentMessage(id: "answer", text: "Reply")], turnID: "turn")))
        let rowID = try #require(snapshot.items.first?.id)
        let anchor = try #require(TranscriptReadingAnchor(rowID: rowID,
            frame: CGRect(x: 0, y: 1_000, width: 600, height: 800),
            viewport: CGRect(x: 0, y: 1_400, width: 600, height: 300)))
        original.readingPosition.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: "first-loaded")
        var cache = RecentConversationCache(capacity: 8)
        cache.record(snapshot, session: original)
        for index in 0..<8 {
            let session = await registry.session(threadID: "other-\(index)")
            let next = await session.merge(.fixture(threadID: "other-\(index)", wire: entries([
                .agentMessage(id: "answer", text: "Other reply")], turnID: "turn")))
            cache.record(next, session: session)
        }
        #expect(cache.presentation(threadID: "reading") == nil)
        let resolved = await registry.session(threadID: "reading")
        #expect(resolved === original)
        #expect(!resolved.readingPosition.isFollowingLatest)
        #expect(resolved.readingPosition.anchor == anchor)
        #expect(resolved.readingPosition.mountedStartRowID == "first-loaded")
        await registry.invalidate(threadID: "reading")
        for index in 0..<8 { await registry.invalidate(threadID: "other-\(index)") }
    }

    @Test func aCachedFollowerReturnsToLatestInsteadOfAnOldReadingAnchor() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let original = await registry.session(threadID: "following")
        let snapshot = await original.merge(.fixture(threadID: "following", wire: entries([.agentMessage(id: "answer", text: "Reply")], turnID: "turn")))
        let anchor = try #require(TranscriptReadingAnchor(rowID: "answer",
            frame: CGRect(x: 0, y: 100, width: 600, height: 800),
            viewport: CGRect(x: 0, y: 200, width: 600, height: 500)))
        original.readingPosition.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: "old-start")
        var cache = RecentConversationCache(capacity: 8)
        cache.record(snapshot, session: original)
        original.readingPosition.record(isFollowingLatest: true, anchor: anchor, mountedStartRowID: "old-start")
        _ = await registry.session(threadID: "away")
        let restored = try #require(cache.presentation(threadID: "following")?.session?.readingPosition)
        #expect(restored.isFollowingLatest)
        #expect(restored.anchor == nil)
        #expect(restored.mountedStartRowID == nil)
        await registry.invalidate(threadID: "following")
        await registry.invalidate(threadID: "away")
    }

    @Test func anEvictedSessionReleasesItsReadingPositionEvenWhenTheSeedRemainsCached() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        var original: ConversationSession? = await registry.session(threadID: "evicted")
        var cache = RecentConversationCache(capacity: 8)
        if let original {
            let snapshot = await original.merge(.fixture(threadID: "evicted", wire: entries([.agentMessage(id: "answer", text: "Retained seed")], turnID: "turn")))
            cache.record(snapshot, session: original)
        }
        weak let position = original?.readingPosition
        weak let rowStates = original?.rowPresentations
        let rowID = cache.presentation(threadID: "evicted")?.items.first?.id
        weak let expandedState = rowID.flatMap { original?.rowPresentations.state(for: $0) }
        expandedState?.setCodeExpanded(0, expanded: true, isStreaming: false)
        original = nil
        for index in 0..<20 { _ = await registry.session(threadID: "other-\(index)") }
        #expect(position == nil)
        #expect(rowStates == nil)
        #expect(expandedState == nil)
        #expect(cache.presentation(threadID: "evicted") != nil)
        #expect(cache.presentation(threadID: "evicted")?.session?.readingPosition == nil)
        let reopened = await registry.session(threadID: "evicted")
        #expect(reopened.readingPosition.isFollowingLatest)
        #expect(reopened.readingPosition.anchor == nil)
        await registry.invalidate(threadID: "evicted")
        for index in 0..<20 { await registry.invalidate(threadID: "other-\(index)") }
    }
    @Test func aSwitchRestoresTheNearestSupportedAnchorAtBothBandEdgesAndEqualHeight() throws {
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 500)
        let cases: [(CGFloat, CGFloat, CGFloat, Bool)] = [
            (-100, 449, -1.9607843137254901, false),
            (-100, 450, -2, false),
            (-100, 451, -2, true),
            (-100, 499.75, -2, true),
            (-100, 500, 0, true),
            (-100, 500.25, 2, true),
            (-100, 549, 2, true),
            (-100, 550, 2, false),
            (-100, 551, 1.9607843137254901, false),
            (0, 500, 0, false),
            (100, 450, 2, false),
            (100, 451, 2, true),
            (100, 549, -2, true),
            (100, 550, -2, false),
        ]
        for (rowY, rowHeight, expected, isClamped) in cases {
            let anchor = try #require(TranscriptReadingAnchor(rowID: "reply",
                frame: CGRect(x: 0, y: rowY, width: 600, height: rowHeight), viewport: viewport))
            let actual = anchor.alignment
            #expect(abs(actual.fraction - expected) < 1e-12)
            #expect(abs(actual.fraction) <= 2)
            #expect(actual.isClamped == isClamped)
        }
    }

    @Test func aSwitchCapturesItsOwnWindowAfterAnotherWindowHasScrolled() throws {
        let position = TranscriptReadingPosition()
        let firstScope = UUID()
        let secondScope = UUID()
        let frame = CGRect(x: 0, y: 1_000, width: 600, height: 1_200)
        let firstAnchor = try #require(TranscriptReadingAnchor(rowID: "reply", frame: frame,
            viewport: CGRect(x: 0, y: 1_123.5, width: 600, height: 300)))
        let secondAnchor = try #require(TranscriptReadingAnchor(rowID: "reply", frame: frame,
            viewport: CGRect(x: 0, y: 1_700, width: 600, height: 300)))
        let first = Capture(position: position, anchor: firstAnchor)
        let second = Capture(position: position, anchor: secondAnchor)
        position.attach(first, scope: firstScope)
        position.attach(second, scope: secondScope)
        second.captureReadingPosition()
        #expect(position.anchor?.rowOffset == 700)
        position.capture(scope: firstScope)
        #expect(position.anchor?.rowOffset == 123.5)
        #expect(first.captures == 1)
        #expect(second.captures == 1)
        position.detach(first, scope: firstScope)
        position.capture(scope: secondScope)
        #expect(position.anchor?.rowOffset == 700)
        #expect(first.captures == 1)
        #expect(second.captures == 2)
    }

    private final class Capture: TranscriptReadingPositionCapturing {
        private let position: TranscriptReadingPosition
        private let anchor: TranscriptReadingAnchor
        private(set) var captures = 0

        init(position: TranscriptReadingPosition, anchor: TranscriptReadingAnchor) {
            self.position = position
            self.anchor = anchor
        }

        func captureReadingPosition() {
            captures += 1
            position.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: nil)
        }
    }
}
