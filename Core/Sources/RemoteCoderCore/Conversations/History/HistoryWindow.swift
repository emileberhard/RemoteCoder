import Foundation

struct HistoryRange<Element: Codable & Sendable & Identifiable>: Codable, Sendable where Element.ID == String {
    struct Page: Codable, Sendable {
        var elements: [Element]
        var older: String?
        var newer: String?
        let fetchedAt: Date
        var encodedBytes: Int?

        init(elements: [Element], older: String?, newer: String?, fetchedAt: Date) {
            self.elements = elements
            self.older = older
            self.newer = newer
            self.fetchedAt = fetchedAt
        }

        init(_ data: [Element], next: String?, backwards: String?, direction: CodexAppServerV2.SortDirection,
             placement: Placement, fetchedAt: Date) {
            if direction == .desc {
                self.init(elements: data.reversed(), older: next, newer: placement.readsTail ? nil : backwards, fetchedAt: fetchedAt)
            } else {
                self.init(elements: data, older: backwards, newer: next, fetchedAt: fetchedAt)
            }
        }
    }

    enum Placement: Hashable, Codable, Sendable {
        case tail
        case reset
        case older(String)
        case newer(String)

        var readsTail: Bool {
            switch self {
            case .tail, .reset: true
            case .older, .newer: false
            }
        }
    }

    private(set) var pages: [Page] = []

    var isLoaded: Bool { !pages.isEmpty }
    var older: String? { pages.first?.older }
    var newer: String? { pages.last?.newer }
    var count: Int { pages.reduce(0) { $0 + $1.elements.count } }
    var encodedBytes: Int { pages.reduce(0) { $0 + ($1.encodedBytes ?? 0) } }

    enum End: Sendable { case oldest, newest }

    @discardableResult
    mutating func insert(_ page: Page, at placement: Placement) -> Bool {
        switch placement {
        case .tail:
            spliceTail(page)
        case .reset:
            pages = [page]
        case .older(let cursor):
            guard isLoaded, older == cursor else { return false }
            let fresh = absorbing(page)
            if fresh.elements.isEmpty { pages[0].older = fresh.older } else { pages.insert(fresh, at: 0) }
        case .newer(let cursor):
            guard isLoaded, newer == cursor else { return false }
            let fresh = absorbing(page)
            if fresh.elements.isEmpty { pages[pages.count - 1].newer = fresh.newer } else { pages.append(fresh) }
        }
        return true
    }

    mutating func removePage(at end: End) {
        guard pages.count > 1 else { return }
        switch end {
        case .oldest:
            pages.removeFirst()
        case .newest:
            pages.removeLast()
            while pages.count > 1, pages[pages.count - 1].newer == nil { pages.removeLast() }
        }
    }

    mutating func removePages(at end: End, while isUnused: (Page) -> Bool) {
        while pages.count > 1, let edge = end == .oldest ? pages.first : pages.last, isUnused(edge) {
            removePage(at: end)
        }
    }

    mutating func measure(_ bytes: (Page) -> Int) {
        for index in pages.indices where pages[index].encodedBytes == nil {
            pages[index].encodedBytes = bytes(pages[index])
        }
    }

    private mutating func spliceTail(_ tail: Page) {
        let incoming = Set(tail.elements.map(\.id))
        guard newer == nil, let oldest = tail.elements.first,
              let boundary = pages.firstIndex(where: { $0.elements.contains { $0.id == oldest.id } }) else {
            pages = [tail]
            return
        }
        var kept = Array(pages[...boundary])
        kept[boundary].elements = Array(kept[boundary].elements.prefix { $0.id != oldest.id })
        for index in kept.indices {
            let before = kept[index].elements.count
            kept[index].elements.removeAll { incoming.contains($0.id) }
            if index == boundary || kept[index].elements.count != before {
                kept[index].encodedBytes = nil
                kept[index].newer = nil
            }
        }
        if kept.count > 1 || !kept[0].elements.isEmpty { kept.removeAll { $0.elements.isEmpty } }
        else { kept.removeAll() }
        pages = kept + [tail]
    }

    private mutating func absorbing(_ page: Page) -> Page {
        let updates = Dictionary(page.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var present = Set<String>()
        for index in pages.indices {
            for (offset, element) in pages[index].elements.enumerated() {
                present.insert(element.id)
                guard let update = updates[element.id], pages[index].fetchedAt <= page.fetchedAt else { continue }
                pages[index].elements[offset] = update
                pages[index].encodedBytes = nil
            }
        }
        var fresh = page
        fresh.elements.removeAll { present.contains($0.id) }
        if fresh.elements.count != page.elements.count { fresh.encodedBytes = nil }
        return fresh
    }
}

struct HistoryWindow: Codable, Sendable {
    typealias Entry = CodexAppServerV2.ThreadItemsListResponse.Entry
    typealias Placement = HistoryRange<Entry>.Placement
    typealias ItemPage = HistoryRange<Entry>.Page
    typealias TurnPage = HistoryRange<CodexAppServerV2.Turn>.Page

    static let entryLimit = 2_000
    static let byteBudget = 16 * 1_024 * 1_024

    struct Turn: Sendable {
        let id: String
        let entries: [Entry]
        let metadata: CodexAppServerV2.Turn?
    }

    struct Update: Sendable {
        struct Metadata: Sendable {
            let page: TurnPage
            let placement: HistoryRange<CodexAppServerV2.Turn>.Placement
        }
        var items: ItemPage
        let placement: Placement
        var metadata: [Metadata]
    }

    private(set) var items = HistoryRange<Entry>()
    private(set) var metadata = HistoryRange<CodexAppServerV2.Turn>()
    private(set) var turns: [Turn] = []
    private var turnIndex: [String: Int] = [:]

    var isLoaded: Bool { items.isLoaded }
    var older: String? { items.older }
    var newer: String? { items.newer }
    var fetchedAt: Date { items.pages.map(\.fetchedAt).min() ?? .distantPast }
    var encodedBytes: Int { items.encodedBytes + metadata.encodedBytes }
    var olderEdge: HistoryEdge? { isLoaded ? older.map { HistoryEdge(kind: .older, cursor: $0) } : nil }
    var newerEdge: HistoryEdge? { isLoaded ? newer.map { HistoryEdge(kind: .newer, cursor: $0) } : nil }
    var hasRoomToPrefetch: Bool { items.count <= Self.entryLimit / 2 && encodedBytes <= Self.byteBudget / 2 }

    var turnsLackingMetadata: Set<String> {
        Set(turns.filter { $0.metadata == nil }.map(\.id))
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode(HistoryRange<Entry>.self, forKey: .items)
        metadata = try container.decode(HistoryRange<CodexAppServerV2.Turn>.self, forKey: .metadata)
        rebuild()
    }

    private enum CodingKeys: String, CodingKey { case items, metadata }

    func turn(_ id: String) -> Turn? { turnIndex[id].map { turns[$0] } }

    @discardableResult
    mutating func apply(_ update: Update) -> Bool {
        if case .tail = update.placement, newer != nil { return false }
        guard items.insert(update.items, at: update.placement) else { return false }
        for turns in update.metadata { metadata.insert(turns.page, at: turns.placement) }
        items.measure(Self.encodedBytes)
        metadata.measure(Self.encodedBytes)
        enforceBudget(reading: update.placement)
        rebuild()
        return true
    }

    mutating func apply(_ turns: Update.Metadata) {
        guard metadata.insert(turns.page, at: turns.placement) else { return }
        metadata.measure(Self.encodedBytes)
        rebuild()
    }

    private static func encodedBytes<Page: Encodable>(_ page: Page) -> Int {
        (try? JSONEncoder().encode(page).count) ?? byteBudget
    }

    private mutating func enforceBudget(reading placement: Placement) {
        let far: HistoryRange<Entry>.End
        switch placement {
        case .older: far = .newest
        case .tail, .reset, .newer: far = .oldest
        }
        while items.pages.count > 1, items.count > Self.entryLimit || encodedBytes > Self.byteBudget {
            items.removePage(at: far)
        }
        let referenced = Set(items.pages.flatMap { $0.elements.map(\.turnId) })
        metadata.removePages(at: far == .oldest ? .oldest : .newest) { page in
            page.elements.allSatisfy { !referenced.contains($0.id) }
        }
    }

    private mutating func rebuild() {
        let known = Dictionary(metadata.pages.flatMap(\.elements).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var order: [String] = []
        var grouped: [String: [Entry]] = [:]
        for page in items.pages {
            for entry in page.elements {
                if grouped[entry.turnId] == nil { order.append(entry.turnId) }
                grouped[entry.turnId, default: []].append(entry)
            }
        }
        turns = order.map { Turn(id: $0, entries: grouped[$0, default: []], metadata: known[$0]) }
        turnIndex = Dictionary(uniqueKeysWithValues: turns.enumerated().map { ($0.element.id, $0.offset) })
    }
}

struct HistoryEdge: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case older
        case newer
        case reload(turnID: String)
    }

    enum Status: Sendable, Equatable {
        case loading
        case failed
    }

    let kind: Kind
    let cursor: String?

    var id: String {
        switch kind {
        case .older: "history-edge-older"
        case .newer: "history-edge-newer"
        case .reload(let turnID): "history-edge-reload-\(turnID)"
        }
    }
}
