import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct TranscriptSurfaceRetentionTests {
    @Test func aReturnReusesTheSurfaceAndTheFourthDetachedConversationEvictsTheOldest() throws {
        let retention = TranscriptSurfaceRetention(capacity: 3)
        let positions = (0..<4).map { _ in TranscriptReadingPosition() }
        let surfaces = (0..<4).map { _ in Surface() }
        let scopes = positions.map { _ in retention.scope(owner: UUID()) }
        for index in 0..<3 { #expect(scopes[index].retain(surfaces[index], for: positions[index])) }
        let returned = try #require(scopes[0].take(for: positions[0]))
        #expect(returned === surfaces[0])
        #expect(surfaces.allSatisfy { $0.discards == 0 })
        #expect(scopes[0].retain(returned, for: positions[0]))
        #expect(scopes[3].retain(surfaces[3], for: positions[3]))
        #expect(surfaces[1].discards == 1)
        #expect(scopes[1].surface(for: positions[1]) == nil)
        #expect(scopes[0].surface(for: positions[0]) === surfaces[0])
        #expect(scopes[2].surface(for: positions[2]) === surfaces[2])
        #expect(scopes[3].surface(for: positions[3]) === surfaces[3])
        retention.removeAll()
        #expect(surfaces.map(\.discards) == [1, 1, 1, 1])
    }

    @Test func selectingTheReturnProtectsItWhenTheDepartingSurfaceDetachesBeforeMount() throws {
        let retention = TranscriptSurfaceRetention(capacity: 3)
        let positions = (0..<4).map { _ in TranscriptReadingPosition() }
        let surfaces = (0..<4).map { _ in Surface() }
        let scopes = positions.map { _ in retention.scope(owner: UUID()) }
        for index in 0..<3 { #expect(scopes[index].retain(surfaces[index], for: positions[index])) }
        let selected = try #require(scopes[0].surface(for: positions[0]))
        #expect(scopes[3].retain(surfaces[3], for: positions[3]))
        let mounted = try #require(scopes[0].take(for: positions[0]))
        #expect(mounted === selected)
        #expect(surfaces[0].discards == 0)
        #expect(surfaces[1].discards == 1)
    }

    @Test func preparedSourceAndRenderChangesDiscardOnlyTheirDetachedSurfaceBeforePublication() {
        let retention = TranscriptSurfaceRetention(capacity: 3)
        let first = TranscriptReadingPosition()
        let second = TranscriptReadingPosition()
        first.prepareSource(revision: 10)
        second.prepareSource(revision: 20)
        let firstSurface = Surface()
        let secondSurface = Surface()
        let firstScope = retention.scope(owner: UUID())
        let secondScope = retention.scope(owner: UUID())
        #expect(firstScope.retain(firstSurface, for: first))
        #expect(secondScope.retain(secondSurface, for: second))
        first.prepareSource(revision: 10)
        first.prepareSource(revision: 9)
        #expect(firstSurface.discards == 0)
        first.prepareSource(revision: 11)
        #expect(firstSurface.discards == 1)
        #expect(secondSurface.discards == 0)
        retention.prepareRenderChange(firstSurface.messageID, in: ObjectIdentifier(firstSurface))
        #expect(secondSurface.discards == 0)
        retention.prepareRenderChange(secondSurface.messageID, in: ObjectIdentifier(secondSurface))
        #expect(secondSurface.discards == 1)
        #expect(secondScope.take(for: second) == nil)
    }

    @Test func activeCompactionAndLoadingHistoryCannotRetainTheirAnimatingRoots() {
        for phase in [ConversationCompaction.Phase.requesting, .running] {
            let marker = CompactionMarker(id: "compact", compaction: ConversationCompaction(turnID: "turn", phase: phase))
            #expect(!TranscriptSurfaceRetention.hasQuiescentContent(.compaction(marker), historyEdgeStatus: nil))
        }
        let settled = CompactionMarker(id: "compact", compaction: ConversationCompaction(turnID: "turn", phase: .completed))
        #expect(TranscriptSurfaceRetention.hasQuiescentContent(.compaction(settled), historyEdgeStatus: nil))
        let edge = ChatStreamItem.historyEdge(HistoryEdge(kind: .older, cursor: "before"))
        #expect(!TranscriptSurfaceRetention.hasQuiescentContent(edge, historyEdgeStatus: .loading))
        #expect(TranscriptSurfaceRetention.hasQuiescentContent(edge, historyEdgeStatus: .failed))
        #expect(TranscriptSurfaceRetention.hasQuiescentContent(edge, historyEdgeStatus: nil))
    }

    @Test func releasingTheSessionPositionDiscardsItsDetachedSurfaceWithoutRetainingTheSession() {
        let retention = TranscriptSurfaceRetention(capacity: 3)
        var position: TranscriptReadingPosition? = TranscriptReadingPosition()
        let surface = Surface()
        if let position { #expect(retention.scope(owner: UUID()).retain(surface, for: position)) }
        weak let released = position
        position = nil
        #expect(released == nil)
        #expect(surface.discards == 1)
    }

    @Test func twoWindowsReturningToTheSameSessionKeepSeparateNativeOwners() throws {
        let retention = TranscriptSurfaceRetention(capacity: 3)
        let position = TranscriptReadingPosition()
        position.prepareSource(revision: 1)
        let first = retention.scope(owner: UUID())
        let second = retention.scope(owner: UUID())
        let firstSurface = Surface()
        let secondSurface = Surface()
        #expect(first.retain(firstSurface, for: position))
        #expect(second.retain(secondSurface, for: position))
        let returned = try #require(first.take(for: position))
        #expect(returned === firstSurface)
        #expect(first.surface(for: position) == nil)
        #expect(second.surface(for: position) === secondSurface)
        position.prepareSource(revision: 2)
        #expect(secondSurface.discards == 1)
        #expect(firstSurface.discards == 0)
    }

    private final class Surface: RetainedTranscriptSurface {
        var renderStoreID: ObjectIdentifier? { ObjectIdentifier(self) }
        let messageID = UUID()
        private(set) var discards = 0
        func discardRetainedSurface() { discards += 1 }
        func observesRenderedMessage(_ id: UUID, in store: ObjectIdentifier) -> Bool {
            id == messageID && store == ObjectIdentifier(self)
        }
    }
}
