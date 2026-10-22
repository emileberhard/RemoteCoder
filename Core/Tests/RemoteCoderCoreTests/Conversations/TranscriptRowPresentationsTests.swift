import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct TranscriptRowPresentationsTests: ConversationHistoryFixtures {
    @Test func anAddedRowsPublishedMembershipSurvivesRejectedMemosAcrossStreamingRevisions() async throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: entries([.agentMessage(id: "settled", text: "Settled reply")], turnID: "history")))
        var publication = ConversationProjection.Publication()
        let prepared = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
        let firstCandidate = publication.apply(prepared, currentRevision: state.revision)
        let first = try #require(firstCandidate)
        let position = TranscriptReadingPosition()
        let store = TranscriptRowPresentations()
        store.prepareSource(first, readingPosition: position)
        let settledID = try #require(first.items.first?.id)
        let flags = store.state(for: settledID)
        flags.setCodeExpanded(0, expanded: true, isStreaming: false)

        state.apply(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "answer", text: "Live reply"),
            threadID: "thread", turnID: "live", ordinal: 0, startedAtMs: 3_000, completedAtMs: 3_001))
        let added = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
        state.apply(try GatewayEventFixture.delta(" first", threadID: "thread", turnID: "live", itemID: "answer"))
        let concurrent = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
        state.apply(try GatewayEventFixture.delta(" second", threadID: "thread", turnID: "live", itemID: "answer"))
        let publishedCandidate = publication.apply(added, currentRevision: state.revision)
        let published = try #require(publishedCandidate)
        #expect(published.presentationRows.rowIDs.count == first.presentationRows.rowIDs.count + 1)
        store.prepareSource(published, readingPosition: position)
        let membership = try #require(store.sourceIdentity)
        let concurrentCandidate = publication.apply(concurrent, currentRevision: state.revision)
        let concurrentPublication = try #require(concurrentCandidate)
        #expect(concurrentPublication.presentationRows.identity == membership)
        store.prepareSource(concurrentPublication, readingPosition: position)
        for index in 0..<8 {
            let next = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
            #expect(next.snapshot.presentationRows.identity == membership)
            state.apply(try GatewayEventFixture.delta(" \(index)", threadID: "thread", turnID: "live", itemID: "answer"))
            let snapshotCandidate = publication.apply(next, currentRevision: state.revision)
            let snapshot = try #require(snapshotCandidate)
            store.prepareSource(snapshot, readingPosition: position)
            #expect(store.sourceIdentity == membership)
            #expect(store.state(for: settledID) === flags)
            #expect(flags.codeIsExpanded(0, isStreaming: false))
        }
        state.apply(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "another", text: "Another row"),
            threadID: "thread", turnID: "live", ordinal: 1, startedAtMs: 4_000, completedAtMs: 4_001))
        let newer = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
        state.apply(try GatewayEventFixture.delta(" after", threadID: "thread", turnID: "live", itemID: "answer"))
        let changedCandidate = publication.apply(newer, currentRevision: state.revision)
        let changed = try #require(changedCandidate)
        #expect(changed.presentationRows.rowIDs.count == published.presentationRows.rowIDs.count + 1)
        #expect(changed.presentationRows.identity != membership)
        store.prepareSource(changed, readingPosition: position)
        let older = publication.apply(added, currentRevision: state.revision)
        #expect(older == nil)
        let current = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
        #expect(current.snapshot.presentationRows.identity == changed.presentationRows.identity)
        #expect(store.sourceIdentity == changed.presentationRows.identity)
        let acceptedCandidate = publication.apply(current, currentRevision: state.revision)
        let accepted = try #require(acceptedCandidate)
        #expect(accepted.presentationRows.identity == changed.presentationRows.identity)
        let rejected = publication.apply(added, currentRevision: state.revision)
        #expect(rejected == nil)
        let reused = await ConversationProjection.render(state, memo: publication.preparationMemo, signposter: ConversationProjection.signposter)
        #expect(reused.memo.projectedTurnCount == 0)
        #expect(reused.snapshot.presentationRows.identity == changed.presentationRows.identity)
    }

    @Test func anExpandedBlockReturnsToTheSameAnchorLineThroughTheCachedSession() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let original = await registry.session(threadID: "expanded")
        let snapshot = await original.merge(.fixture(threadID: "expanded", wire: entries([
            .agentMessage(id: "answer", text: "```swift\n" + (0..<60).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n```")
        ], turnID: "turn")))
        let rowID = try #require(snapshot.items.first?.id)
        #expect(original.rowPresentations.count == 0)
        let flags = original.rowPresentations.state(for: rowID)
        flags.setCodeExpanded(0, expanded: true, isStreaming: false)
        flags.mermaidSource[1] = true
        flags.timelineExpanded = true
        flags.questionExpandedFreeText = [0]
        flags.questionExpandedOptions = [1]
        let resendID = UUID()
        flags.questionResendID = resendID
        let anchor = try #require(TranscriptReadingAnchor(rowID: rowID,
            frame: CGRect(x: 0, y: 1_000, width: 600, height: 1_200),
            viewport: CGRect(x: 0, y: 1_756, width: 600, height: 600)))
        original.readingPosition.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: rowID)
        var cache = RecentConversationCache(capacity: 8)
        cache.record(snapshot, session: original)
        _ = await registry.session(threadID: "away")
        let restored = try #require(cache.presentation(threadID: "expanded")?.session)
        let restoredFlags = restored.rowPresentations.state(for: rowID)
        #expect(restoredFlags === flags)
        #expect(restoredFlags.codeIsExpanded(0, isStreaming: false))
        #expect(restoredFlags.mermaidSource[1] == true)
        #expect(restoredFlags.timelineExpanded)
        #expect(restoredFlags.questionExpandedFreeText == [0])
        #expect(restoredFlags.questionExpandedOptions == [1])
        #expect(restoredFlags.questionResendID == resendID)
        let saved = try #require(restored.readingPosition.anchor)
        #expect(saved.rowID == rowID)
        let restoredOffset = saved.origin(rowMinY: 3_000, viewportHeight: 600) - 3_000
        #expect(restoredOffset == 756)
        #expect((restoredOffset - 36) / 18 == 40)
        await registry.invalidate(threadID: "expanded")
        await registry.invalidate(threadID: "away")
    }

    @Test func textAndTimelineExpansionReusePreparedMembershipIncludingCollapsedActivity() throws {
        let command = CodexAppServerV2.ThreadItem.commandExecution(id: "tool", command: "echo done", cwd: "/tmp",
            status: .completed, commandActions: [], aggregatedOutput: "done", exitCode: 0, durationMs: 1)
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: entries([command], turnID: "history")))
        state.apply(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "answer", text: ""),
            threadID: "thread", turnID: "turn", ordinal: 0, startedAtMs: 3_000, completedAtMs: 3_001))
        state.apply(try GatewayEventFixture.delta("Reply", threadID: "thread", turnID: "turn", itemID: "answer"))
        var memo = ConversationProjection.Memo()
        let first = ConversationProjection.project(state, memo: &memo)
        let timeline = try #require(first.timelines.first)
        let event = try #require(timeline.events.first)
        #expect(!timeline.isExpanded)
        #expect(first.presentationRows.rowIDs.contains(ChatStreamItem.activityRowID(eventID: event.id)))
        state.apply(try GatewayEventFixture.delta(" grown", threadID: "thread", turnID: "turn", itemID: "answer"))
        let grown = ConversationProjection.project(state, memo: &memo)
        #expect(grown.messages.last?.text == "Reply grown")
        #expect(grown.presentationRows.identity == first.presentationRows.identity)
        state.toggleTimeline(timeline.id)
        let expanded = ConversationProjection.project(state, memo: &memo)
        #expect(expanded.timelines.first?.isExpanded == true)
        #expect(expanded.presentationRows.identity == first.presentationRows.identity)
        state.apply(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "another", text: "Another row"),
            threadID: "thread", turnID: "turn", ordinal: 1, startedAtMs: 4_000, completedAtMs: 4_001))
        let added = ConversationProjection.project(state, memo: &memo)
        #expect(added.presentationRows.identity != first.presentationRows.identity)
        #expect(added.presentationRows.rowIDs.count == first.presentationRows.rowIDs.count + 1)
    }

    @Test func historyMembershipPrunesFlagsAndRejectsAnOlderPreparedSnapshot() {
        let position = TranscriptReadingPosition()
        let store = TranscriptRowPresentations()
        store.prepareSource(snapshot(revision: 1, rows: ["first", "second"]), readingPosition: position)
        #expect(store.count == 0)
        let first = store.state(for: "first")
        first.setCodeExpanded(0, expanded: true, isStreaming: false)
        let second = store.state(for: "second")
        second.timelineExpanded = true
        #expect(store.count == 2)
        store.prepareSource(snapshot(revision: 2, rows: ["second"]), readingPosition: position)
        #expect(store.count == 1)
        #expect(store.state(for: "second") === second)
        store.prepareSource(snapshot(revision: 1, rows: ["first"]), readingPosition: position)
        #expect(store.state(for: "second").timelineExpanded)
        #expect(!store.state(for: "first").codeIsExpanded(0, isStreaming: false))
        #expect(store.count == 1)
    }

    @Test func aFlagChangeEvictsAnotherWindowsDetachedRootBeforeItsObservedValueChanges() {
        let retention = TranscriptSurfaceRetention(capacity: 3)
        let position = TranscriptReadingPosition()
        let store = TranscriptRowPresentations()
        store.prepareSource(snapshot(revision: 1, rows: ["reply"]), readingPosition: position)
        let state = store.state(for: "reply")
        let surface = Surface(state: state)
        #expect(retention.scope(owner: UUID()).retain(surface, for: position))
        state.setCodeExpanded(0, expanded: true, isStreaming: false)
        #expect(surface.discards == 1)
        #expect(surface.wasExpandedAtDiscard == false)
        #expect(state.codeIsExpanded(0, isStreaming: false))
        #expect(retention.count == 0)
    }

    private func snapshot(revision: UInt64, rows: Set<String>) -> ConversationSnapshot {
        ConversationSnapshot(conversationID: UUID(), ownerID: UUID(), threadID: "reading", revision: revision,
            messages: [], timelines: [], items: [], lastTurnCompletedAt: nil, presentationRows: TranscriptPresentationRows(rowIDs: rows))
    }

    private final class Surface: RetainedTranscriptSurface {
        var renderStoreID: ObjectIdentifier? { nil }
        private let state: TranscriptRowPresentationState
        private(set) var discards = 0
        private(set) var wasExpandedAtDiscard: Bool?
        init(state: TranscriptRowPresentationState) { self.state = state }
        func discardRetainedSurface() {
            discards += 1
            wasExpandedAtDiscard = state.codeIsExpanded(0, isStreaming: false)
        }
        func observesRenderedMessage(_ id: UUID, in store: ObjectIdentifier) -> Bool { false }
    }
}
