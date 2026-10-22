import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryWindowTests {
    private func entry(_ id: String, turn: String, ordinal: Int64? = nil, text: String? = nil) -> HistoryWindow.Entry {
        .init(turnId: turn, item: .agentMessage(id: id, text: text ?? id), startedAtOrdinal: ordinal, isComplete: true)
    }

    private func turn(_ id: String) -> CodexAppServerV2.Turn {
        .init(id: id, items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)
    }

    private func update(_ wire: [HistoryWindow.Entry], next: String?, backwards: String? = nil,
                        direction: CodexAppServerV2.SortDirection = .desc, placement: HistoryWindow.Placement,
                        fetchedAt: Date = Date(timeIntervalSince1970: 1),
                        turns: [CodexAppServerV2.Turn] = []) -> HistoryWindow.Update {
        let metadataPlacement: HistoryRange<CodexAppServerV2.Turn>.Placement = placement == .reset ? .reset : .tail
        return .init(items: .init(wire, next: next, backwards: backwards, direction: direction, placement: placement, fetchedAt: fetchedAt),
            placement: placement,
            metadata: turns.isEmpty ? [] : [.init(page: .init(turns, next: nil, backwards: nil, direction: .desc,
                placement: metadataPlacement, fetchedAt: fetchedAt), placement: metadataPlacement)])
    }

    private func ids(_ window: HistoryWindow) -> [String] {
        window.turns.flatMap { $0.entries.map(\.item.id) }
    }

    @Test func oneCursorPairGrowsOlderAndTheTailSplicesOnTop() {
        var window = HistoryWindow()
        #expect(window.olderEdge == nil && window.newerEdge == nil)
        let tailApplied = window.apply(update([entry("e5", turn: "b"), entry("e4", turn: "b"), entry("e3", turn: "a")],
            next: "c3", backwards: "b5", placement: .tail))
        #expect(tailApplied)
        #expect(ids(window) == ["e3", "e4", "e5"])
        #expect(window.turns.map(\.id) == ["a", "b"])
        #expect(window.olderEdge == HistoryEdge(kind: .older, cursor: "c3"))
        #expect(window.newerEdge == nil)

        let staleApplied = window.apply(update([entry("x", turn: "a")], next: nil, placement: .older("stale")))
        #expect(!staleApplied)
        let olderApplied = window.apply(update([entry("e2", turn: "a"), entry("e1", turn: "a")], next: nil, backwards: "b2", placement: .older("c3")))
        #expect(olderApplied)
        #expect(ids(window) == ["e1", "e2", "e3", "e4", "e5"])
        #expect(window.olderEdge == nil)

        let spliceApplied = window.apply(update([entry("e7", turn: "c"), entry("e6", turn: "c"), entry("e5", turn: "b", text: "edited")],
            next: "c5", placement: .tail))
        #expect(spliceApplied)
        #expect(ids(window) == ["e1", "e2", "e3", "e4", "e5", "e6", "e7"])
        #expect(window.turn("b")?.entries.last?.item == .agentMessage(id: "e5", text: "edited"))
        #expect(window.older == nil && window.newer == nil)
    }

    @Test func aTailWithoutOverlapReplacesTheWindow() {
        var window = HistoryWindow()
        window.apply(update([entry("e2", turn: "a"), entry("e1", turn: "a")], next: "c1", placement: .tail))
        window.apply(update([entry("e9", turn: "z"), entry("e8", turn: "z")], next: "c8", placement: .tail))
        #expect(ids(window) == ["e8", "e9"])
        #expect(window.olderEdge?.cursor == "c8")

        window.apply(update([entry("r2", turn: "r"), entry("r1", turn: "r")], next: "r0", placement: .reset))
        #expect(ids(window) == ["r1", "r2"])
        #expect(window.older == "r0" && window.newer == nil)
    }

    @Test func readingOlderPastTheLimitEvictsTheNewestPagesAndReadingNewerEvictsTheOldest() {
        let size = 100
        func page(_ index: Int) -> [HistoryWindow.Entry] {
            (0..<size).reversed().map { entry("p\(index)-\($0)", turn: "t\(index)") }
        }
        var window = HistoryWindow()
        window.apply(update(page(0), next: "older-0", placement: .tail))
        for index in 1...20 {
            let olderApplied = window.apply(update(page(index), next: "older-\(index)", backwards: "newer-\(index)", placement: .older("older-\(index - 1)")))
            #expect(olderApplied)
        }
        #expect(window.items.count == HistoryWindow.entryLimit)
        #expect(window.turns.first?.id == "t20")
        #expect(window.turns.last?.id == "t1")
        #expect(window.newerEdge == HistoryEdge(kind: .newer, cursor: "newer-1"))
        let tailApplied = window.apply(update(page(0), next: "older-0", placement: .tail))
        #expect(!tailApplied)

        let newest = page(0).reversed().map { $0 }
        let newerApplied = window.apply(update(newest, next: nil, direction: .asc, placement: .newer("newer-1")))
        #expect(newerApplied)
        #expect(window.items.count == HistoryWindow.entryLimit)
        #expect(window.turns.first?.id == "t19")
        #expect(window.turns.last?.id == "t0")
        #expect(window.newerEdge == nil)
        #expect(window.olderEdge == HistoryEdge(kind: .older, cursor: "older-19"))
    }

    @Test func speculativeReadsHaveRoomOnlyInTheFirstHalfOfTheWindow() {
        func page(_ index: Int) -> [HistoryWindow.Entry] {
            (0..<100).reversed().map { entry("p\(index)-\($0)", turn: "t\(index)") }
        }
        var window = HistoryWindow()
        window.apply(update(page(0), next: "older-0", placement: .tail))
        for index in 1..<10 {
            window.apply(update(page(index), next: "older-\(index)", placement: .older("older-\(index - 1)")))
        }
        #expect(window.items.count == HistoryWindow.entryLimit / 2)
        #expect(window.hasRoomToPrefetch)
        window.apply(update(page(10), next: "older-10", placement: .older("older-9")))
        #expect(!window.hasRoomToPrefetch)
    }

    @Test func evictingARefreshedTailAlsoDropsTheFragmentOnlyItsTailCouldReach() {
        func page(_ index: Int) -> [HistoryWindow.Entry] {
            (0..<100).reversed().map { entry("p\(index)-\($0)", turn: "t\(index)") }
        }
        var window = HistoryWindow()
        window.apply(update(page(0), next: "older-0", placement: .tail))
        let refreshed = (50..<150).reversed().map { entry("p0-\($0)", turn: "t0") }
        window.apply(update(refreshed, next: "older-refresh", placement: .tail))
        #expect(window.items.count == 150)
        for index in 1...19 {
            let applied = window.apply(update(page(index), next: "older-\(index)", backwards: "newer-\(index)",
                placement: .older("older-\(index - 1)")))
            #expect(applied)
        }
        #expect(window.newerEdge == HistoryEdge(kind: .newer, cursor: "newer-1"))
        #expect(!window.turns.contains { $0.id == "t0" })
    }

    @Test func pagingNewerAfterEvictingARefreshedTailSkipsNoEntryTheSpliceTrimmed() throws {
        let base = 2_000
        func desc(_ range: ClosedRange<Int>) -> [HistoryWindow.Entry] { range.reversed().map { entry("e\($0)", turn: "t\($0 / 10)") } }
        var window = HistoryWindow()
        window.apply(update(desc(base + 51...base + 100), next: "before-\(base + 51)", placement: .tail))
        window.apply(update(desc(base + 1...base + 50), next: "before-\(base + 1)", backwards: "after-\(base + 50)",
            placement: .older("before-\(base + 51)")))
        window.apply(update(desc(base + 45...base + 144), next: "before-\(base + 45)", placement: .tail))
        var oldest = base + 1
        while window.newer == nil {
            let applied = window.apply(update(desc(oldest - 100...oldest - 1), next: "before-\(oldest - 100)",
                backwards: "after-\(oldest - 1)", placement: .older("before-\(oldest)")))
            try #require(applied)
            oldest -= 100
        }
        while let cursor = window.newer {
            let after = try #require(Int(cursor.dropFirst("after-".count)))
            let last = min(after + 100, base + 144)
            let applied = window.apply(update((after + 1...last).map { entry("e\($0)", turn: "t\($0 / 10)") },
                next: last == base + 144 ? nil : "after-\(last)", backwards: "before-\(after + 1)", direction: .asc,
                placement: .newer(cursor)))
            try #require(applied)
        }
        let numbers = ids(window).compactMap { Int($0.dropFirst()) }
        #expect(numbers.last == base + 144)
        #expect(numbers == Array(numbers[0]...(base + 144)))
    }

    @Test func overlappingRefreshesKeepEveryRetainedPageInTheBudget() throws {
        let text = String(repeating: "x", count: 100_000)
        var window = HistoryWindow()
        for refresh in 0..<40 {
            let newest = refresh * 5 + 10
            window.apply(update((newest - 10..<newest).reversed().map { entry("e\($0)", turn: "t", text: text) },
                next: "before-\(newest - 10)", placement: .tail))
        }
        let measured = try window.items.pages.reduce(0) { $0 + (try JSONEncoder().encode($1).count) }
        #expect(abs(window.items.encodedBytes - measured) <= 32 * window.items.pages.count)
        #expect(window.encodedBytes <= HistoryWindow.byteBudget)
        #expect(!ids(window).contains("e0"))
        #expect(ids(window).last == "e204")
    }

    @Test func thePartialOldestTurnHoldsOnlyItsCoveredEntries() {
        var window = HistoryWindow()
        window.apply(update([entry("b1", turn: "b", ordinal: 1), entry("a9", turn: "a", ordinal: 9)],
            next: "before-a9", placement: .tail, turns: [turn("b")]))
        #expect(window.turns.map(\.id) == ["a", "b"])
        #expect(window.turn("a")?.entries.map(\.item.id) == ["a9"])
        #expect(window.turnsLackingMetadata == ["a"])
        #expect(window.turn("b")?.metadata?.status == .completed)
        #expect(window.olderEdge?.cursor == "before-a9")

        window.apply(.init(page: .init(elements: [turn("a")], older: nil, newer: nil, fetchedAt: .now), placement: .older("unrelated")))
        #expect(window.turnsLackingMetadata == ["a"])
    }

    @Test func duplicateEntriesUpdateInPlaceWhenFresher() {
        var window = HistoryWindow()
        window.apply(update([entry("e2", turn: "a"), entry("e1", turn: "a", text: "draft")], next: "c1",
            placement: .tail, fetchedAt: Date(timeIntervalSince1970: 1)))
        window.apply(update([entry("e1", turn: "a", text: "final"), entry("e0", turn: "a")], next: nil,
            placement: .older("c1"), fetchedAt: Date(timeIntervalSince1970: 2)))
        #expect(ids(window) == ["e0", "e1", "e2"])
        #expect(window.turn("a")?.entries[1].item == .agentMessage(id: "e1", text: "final"))
    }

    @Test func aRoundTripRebuildsTurnsAndEdges() throws {
        var window = HistoryWindow()
        window.apply(update([entry("b1", turn: "b"), entry("a1", turn: "a")], next: "c1", placement: .tail, turns: [turn("b"), turn("a")]))
        let decoded = try JSONDecoder().decode(HistoryWindow.self, from: JSONEncoder().encode(window))
        #expect(ids(decoded) == ["a1", "b1"])
        #expect(decoded.turn("a")?.metadata?.id == "a")
        #expect(decoded.olderEdge == window.olderEdge)
    }
}
