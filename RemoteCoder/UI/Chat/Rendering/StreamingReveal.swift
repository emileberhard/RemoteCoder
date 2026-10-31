import Foundation

enum StreamingRevealTarget: Hashable, Sendable {
    case text(StreamingRevealTextSlot, utf16: Range<Int>)
    case block(Int)
}

struct StreamingRevealTextSlot: Hashable, Sendable {
    let block: Int
    let slot: Int
}

struct StreamingArrival: Sendable {
    static let none = StreamingArrival(targets: [], stableLengths: [:], continuingBlocks: [], continuations: [])
    private static let unitLimit = 48

    let targets: [StreamingRevealTarget]
    let stableLengths: [StreamingRevealTextSlot: Int]
    let continuingBlocks: Set<Int>
    let continuations: Set<StreamingRevealTarget>

    func carries(_ target: StreamingRevealTarget) -> Bool {
        switch target {
        case .text(let slot, let utf16): utf16.upperBound <= stableLengths[slot, default: 0]
        case .block(let index): continuingBlocks.contains(index)
        }
    }
}

extension StreamingArrival {
    init(previous: [RenderedMarkdownBlock], current: [RenderedMarkdownBlock]) {
        var targets: [StreamingRevealTarget] = []
        var stableLengths: [StreamingRevealTextSlot: Int] = [:]
        var continuingBlocks: Set<Int> = []
        var continuations: Set<StreamingRevealTarget> = []
        for (index, block) in current.enumerated() {
            guard let kind = block.content.revealKind else { continue }
            let old = previous.indices.contains(index) ? previous[index] : nil
            let continues = old?.content.revealKind == kind
            guard let texts = block.content.revealTexts else {
                if continues { continuingBlocks.insert(index) } else { targets.append(.block(index)) }
                continue
            }
            if old == block {
                for position in texts.indices { stableLengths[StreamingRevealTextSlot(block: index, slot: position)] = .max }
                continue
            }
            let oldTexts = continues ? old?.content.revealTexts : nil
            for (position, text) in texts.enumerated() {
                let slot = StreamingRevealTextSlot(block: index, slot: position)
                var stable = 0
                if let oldTexts, oldTexts.indices.contains(position) {
                    stable = StreamingRevealText.commonPrefixLength(oldTexts[position].characters, text.characters)
                    stableLengths[slot] = stable
                }
                let continuesWord = StreamingRevealText.continuesWord(text.characters, at: stable)
                for range in StreamingRevealText.units(in: text.characters, from: stable, limit: Self.unitLimit) {
                    let target = StreamingRevealTarget.text(slot, utf16: range)
                    if continuesWord, range.lowerBound == stable { continuations.insert(target) }
                    targets.append(target)
                }
            }
        }
        self.init(targets: targets, stableLengths: stableLengths, continuingBlocks: continuingBlocks,
                  continuations: continuations)
    }
}

struct StreamingRevealSpan: Equatable, Sendable {
    let utf16: Range<Int>
    let begin: TimeInterval
}

struct StreamingRevealBlock: Equatable, Sendable {
    static let settled = StreamingRevealBlock(cover: nil, slots: [:])

    let cover: TimeInterval?
    let slots: [Int: [StreamingRevealSpan]]

    func spans(slot: Int) -> [StreamingRevealSpan] { slots[slot] ?? [] }
}

struct StreamingReveal: Equatable, Sendable {
    static let settled = StreamingReveal(units: [], schedule: StreamingRevealSchedule())

    private struct Unit: Equatable, Sendable {
        let target: StreamingRevealTarget
        let begin: TimeInterval
    }

    private let units: [Unit]
    private let schedule: StreamingRevealSchedule
    private let blocks: [Int: StreamingRevealBlock]
    let end: TimeInterval?

    private init(units: [Unit], schedule: StreamingRevealSchedule) {
        self.units = units
        self.schedule = schedule
        end = units.map(\.begin).max().map { $0 + StreamingRevealSchedule.fadeDuration }
        var covers: [Int: TimeInterval] = [:]
        var slots: [Int: [Int: [StreamingRevealSpan]]] = [:]
        for unit in units {
            switch unit.target {
            case .block(let index):
                covers[index] = unit.begin
            case .text(let slot, let utf16):
                slots[slot.block, default: [:]][slot.slot, default: []]
                    .append(StreamingRevealSpan(utf16: utf16, begin: unit.begin))
            }
        }
        blocks = Set(covers.keys).union(slots.keys).reduce(into: [:]) { result, index in
            result[index] = StreamingRevealBlock(cover: covers[index], slots: slots[index] ?? [:])
        }
    }

    func block(_ index: Int) -> StreamingRevealBlock { blocks[index] ?? .settled }

    func advanced(by arrival: StreamingArrival, at now: TimeInterval) -> StreamingReveal {
        guard !arrival.targets.isEmpty || !units.isEmpty else { return self }
        var schedule = schedule
        var units = units.filter { $0.begin + StreamingRevealSchedule.fadeDuration > now && arrival.carries($0.target) }
        for target in arrival.targets {
            let word = arrival.continuations.contains(target) ? units.last { $0.target.precedes(target) } : nil
            units.append(Unit(target: target, begin: word?.begin ?? schedule.start(at: now)))
        }
        if !arrival.targets.isEmpty { PerfBuild.count("reveal.arrival") }
        return units.isEmpty ? .settled : StreamingReveal(units: units, schedule: schedule)
    }
}

private extension StreamingRevealTarget {
    func precedes(_ other: Self) -> Bool {
        guard case .text(let slot, let utf16) = self, case .text(let otherSlot, let next) = other else { return false }
        return slot == otherSlot && utf16.upperBound == next.lowerBound
    }
}

private extension RenderedMarkdownBlock.Content {
    enum RevealKind: Equatable {
        case heading(Int), paragraph, quote, list, code, mermaid, table
    }

    var revealKind: RevealKind? {
        switch self {
        case .heading(let level, _): .heading(level)
        case .paragraph: .paragraph
        case .quote: .quote
        case .bulletList: .list
        case .codeBlock: .code
        case .mermaid: .mermaid
        case .table: .table
        case .images, .htmlVisual: nil
        }
    }

    var revealTexts: [AttributedString]? {
        switch self {
        case .heading(_, let content), .paragraph(let content), .quote(let content): [content]
        case .bulletList(let items): items.map(\.content)
        case .images, .htmlVisual, .codeBlock, .mermaid, .table: nil
        }
    }
}
