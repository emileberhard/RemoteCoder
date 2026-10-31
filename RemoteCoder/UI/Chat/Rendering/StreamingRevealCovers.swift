import QuartzCore
import SwiftUI

struct StreamingRevealCover: Equatable {
    let id: Int
    let rects: [CGRect]
    let begin: TimeInterval
}

struct StreamingRevealLayoutMap {
    struct Replacement {
        let source: Range<Int>
        let length: Int
    }

    fileprivate struct Span {
        let id: Int
        let utf16: Range<Int>
        let begin: TimeInterval
    }

    private let text: AttributedString
    private let replacements: [Replacement]
    fileprivate let spans: [Span]

    init(text: AttributedString, spans: [StreamingRevealSpan], replacements: [Replacement]) {
        self.text = text
        self.replacements = replacements
        self.spans = spans.map { span in
            Span(id: span.utf16.lowerBound,
                 utf16: Self.layoutOffset(span.utf16.lowerBound, roundingUp: false, replacements: replacements)
                    ..< Self.layoutOffset(span.utf16.upperBound, roundingUp: true, replacements: replacements),
                 begin: span.begin)
        }
    }

    fileprivate func paragraphStarts() -> [Int] {
        var starts = [0]
        var length = 0
        for character in text.characters {
            length += character.utf16.count
            if character == "\n" || character == "\r" || character == "\r\n" || character == "\u{2029}" {
                starts.append(Self.layoutOffset(length, roundingUp: false, replacements: replacements))
            }
        }
        return starts
    }

    private static func layoutOffset(_ source: Int, roundingUp: Bool, replacements: [Replacement]) -> Int {
        var shift = 0
        for replacement in replacements {
            if source <= replacement.source.lowerBound { break }
            if source < replacement.source.upperBound {
                return replacement.source.lowerBound + shift + (roundingUp ? replacement.length : 0)
            }
            shift += replacement.length - replacement.source.count
        }
        return source + shift
    }
}

extension View {
    @ViewBuilder func streamingRevealCovers(_ map: StreamingRevealLayoutMap?) -> some View {
        if let map {
            overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    StreamingRevealCoverView(covers: layouts.first.map {
                        StreamingRevealCover.covers(for: map, in: $0.layout, at: proxy[$0.origin])
                    } ?? [])
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            self
        }
    }

    func streamingRevealCover(begin: TimeInterval?) -> some View {
        overlay {
            if let begin {
                GeometryReader { proxy in
                    StreamingRevealCoverView(covers: [
                        StreamingRevealCover(id: 0, rects: [CGRect(origin: .zero, size: proxy.size)], begin: begin),
                    ])
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension StreamingRevealCover {
    static func covers(for map: StreamingRevealLayoutMap, in layout: Text.Layout, at origin: CGPoint) -> [StreamingRevealCover] {
        guard let first = map.spans.map(\.utf16.lowerBound).min() else { return [] }
        var rects: [Int: [CGRect]] = [:]
        var starts: [Int]?
        var paragraph = -1
        var paragraphBase: Text.Layout.CharacterIndex?
        var previousEnd: Text.Layout.CharacterIndex?
        for line in layout {
            let runs = line.map { ($0, $0.characterIndices) }
            guard let low = runs.lazy.flatMap(\.1).min(), let high = runs.lazy.flatMap(\.1).max() else {
                paragraph += 1
                previousEnd = nil
                continue
            }
            if previousEnd.map({ low <= $0 }) ?? true {
                paragraph += 1
                paragraphBase = low
            }
            previousEnd = high
            guard let paragraphBase else { continue }
            let start: Int
            if paragraph == 0 {
                start = 0
            } else {
                let known = starts ?? map.paragraphStarts()
                starts = known
                guard known.indices.contains(paragraph) else { break }
                start = known[paragraph]
            }
            guard start + paragraphBase.distance(to: high) >= first else { continue }
            let lineBounds = line.typographicBounds.rect
            var lineRects: [Int: CGRect] = [:]
            for (run, indices) in runs {
                var slice: (span: Int, glyphs: Range<Int>)?
                func close() {
                    guard let slice else { return }
                    let bounds = run[slice.glyphs].typographicBounds.rect
                    let rect = CGRect(x: origin.x + bounds.minX, y: origin.y + lineBounds.minY,
                                      width: bounds.width, height: lineBounds.height)
                    lineRects[slice.span] = lineRects[slice.span]?.union(rect) ?? rect
                }
                for (glyph, index) in indices.enumerated() {
                    let offset = start + paragraphBase.distance(to: index)
                    let span = offset < first ? nil : map.spans.firstIndex { $0.utf16.contains(offset) }
                    if let open = slice, open.span == span, open.glyphs.upperBound == glyph {
                        slice = (open.span, open.glyphs.lowerBound..<(glyph + 1))
                    } else {
                        close()
                        slice = span.map { ($0, glyph..<(glyph + 1)) }
                    }
                }
                close()
            }
            for (span, rect) in lineRects { rects[span, default: []].append(rect) }
        }
        return map.spans.indices.compactMap { index in
            rects[index].map { StreamingRevealCover(id: map.spans[index].id, rects: $0, begin: map.spans[index].begin) }
        }
    }
}

@MainActor
final class StreamingRevealCoverLayers: NSObject {
    private static let frameRate = CAFrameRateRange(minimum: 5, maximum: 30, preferred: 30)
    private let host: CALayer
    private let makeDisplayLink: (Any, Selector) -> CADisplayLink
    private var covers: [Int: (begin: TimeInterval, layers: [CALayer])] = [:]
    private var displayLink: CADisplayLink?

    init(host: CALayer, displayLink: @escaping (Any, Selector) -> CADisplayLink) {
        self.host = host
        makeDisplayLink = displayLink
    }

    func update(_ updated: [StreamingRevealCover], color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let now = CACurrentMediaTime()
        let live = updated.filter { $0.begin + StreamingRevealSchedule.fadeDuration > now }
        let ids = Set(live.map(\.id))
        for (id, cover) in covers where !ids.contains(id) {
            cover.layers.forEach { $0.removeFromSuperlayer() }
        }
        covers = covers.filter { ids.contains($0.key) }
        for cover in live {
            var entry = covers[cover.id] ?? (cover.begin, [])
            entry.begin = cover.begin
            while entry.layers.count > cover.rects.count { entry.layers.removeLast().removeFromSuperlayer() }
            while entry.layers.count < cover.rects.count {
                let layer = CALayer()
                host.addSublayer(layer)
                entry.layers.append(layer)
            }
            let opacity = Self.opacity(from: cover.begin, at: now)
            for (layer, rect) in zip(entry.layers, cover.rects) {
                layer.frame = rect
                layer.backgroundColor = color
                layer.opacity = opacity
            }
            covers[cover.id] = entry
        }
        if covers.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        } else if displayLink == nil {
            let link = makeDisplayLink(self, #selector(tick))
            link.preferredFrameRateRange = Self.frameRate
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        covers.values.forEach { $0.layers.forEach { $0.removeFromSuperlayer() } }
        covers = [:]
    }

    @objc private func tick(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let now = link.targetTimestamp
        for (id, cover) in covers {
            if cover.begin + StreamingRevealSchedule.fadeDuration <= now {
                cover.layers.forEach { $0.removeFromSuperlayer() }
                covers[id] = nil
            } else {
                let opacity = Self.opacity(from: cover.begin, at: now)
                cover.layers.forEach { $0.opacity = opacity }
            }
        }
        if covers.isEmpty {
            link.invalidate()
            displayLink = nil
        }
    }

    private static func opacity(from begin: TimeInterval, at time: TimeInterval) -> Float {
        let progress = min(1, max(0, (time - begin) / StreamingRevealSchedule.fadeDuration))
        return Float(1 - UnitCurve.easeOut.value(at: progress))
    }
}

struct StreamingRevealSettlement: View {
    let end: TimeInterval
    let settle: () -> Void

    var body: some View {
        Color.clear.task(id: end) {
            do { try await Task.sleep(for: .seconds(max(0, end - CACurrentMediaTime()))) } catch { return }
            settle()
        }
    }
}
