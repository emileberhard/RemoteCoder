import SwiftUI

/// Keeps every row in one scroll-target layout. The latest turn reserves enough
/// space to reach the top without nested targets or reparenting older bubbles.
struct TranscriptLayout: Layout {
    let minimumTurnHeight: CGFloat
    let latestTurnIndex: Int?
    static let spacing: CGFloat = 12

    typealias Cache = [CGFloat?: [CGSize]]

    func makeCache(subviews: Subviews) -> Cache { [:] }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let span = PerfBuild.span("layout.updateCache"); defer { span.end() }
        cache.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let span = PerfBuild.span("layout.size"); defer { span.end() }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let sizes = Self.sizes(width: width, of: subviews, cache: &cache)
        let tail = Self.tailPadding(heights: sizes.map(\.height),
            latestTurnIndex: latestTurnIndex,
            minimumTurnHeight: minimumTurnHeight)
        return CGSize(width: width ?? sizes.map(\.width).max() ?? 0,
            height: sizes.reduce(0) { $0 + $1.height } + Self.spacing * CGFloat(max(0, sizes.count - 1)) + tail)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let span = PerfBuild.span("layout.place"); defer { span.end() }
        #if os(iOS)
        PerfBuild.gauge("transcriptSubviews", subviews.count)
        #endif
        let sizes = Self.sizes(width: bounds.width, of: subviews, cache: &cache)
        let tail = Self.tailPadding(heights: sizes.map(\.height),
            latestTurnIndex: latestTurnIndex,
            minimumTurnHeight: minimumTurnHeight)
        var y = bounds.minY
        for index in subviews.indices {
            // The final clear row is the stable jump-to-bottom target.
            if index == subviews.count - 1 { y += tail }
            subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil))
            y += sizes[index].height + Self.spacing
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    private static func sizes(width: CGFloat?, of subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if let sizes = cache[width] { return sizes }
        PerfBuild.count("layout.measure")
        let span = PerfBuild.span("layout.measureMiss"); defer { span.end() }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        if cache.count >= 2 { cache.removeAll(keepingCapacity: true) }
        cache[width] = sizes
        return sizes
    }

    static func isFarFromLatest(latestEnd: CGFloat, visibleBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        latestEnd - visibleBottom > viewportHeight / 2
    }

    static func tailPadding(heights: [CGFloat], latestTurnIndex: Int?, minimumTurnHeight: CGFloat) -> CGFloat {
        guard let start = latestTurnIndex, start < heights.count - 1 else { return 0 }
        let turn = heights[start..<(heights.count - 1)]
        let height = turn.reduce(0, +) + Self.spacing * CGFloat(max(0, turn.count - 1))
        return max(0, minimumTurnHeight - height)
    }
}

#if os(macOS)
struct TranscriptRowLayout: Layout {
    typealias Cache = [CGFloat?: CGSize]

    func makeCache(subviews: Subviews) -> Cache { [:] }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        PerfBuild.count("row.invalidate")
        cache.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        if let size = cache[width] {
            PerfBuild.count("row.cacheHit")
            return size
        }
        PerfBuild.count("row.measure")
        let span = PerfBuild.span("layout.rowMiss"); defer { span.end() }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let size = CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        if cache.count >= 2 { cache.removeAll(keepingCapacity: true) }
        cache[width] = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

struct TranscriptViewport: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
#endif
