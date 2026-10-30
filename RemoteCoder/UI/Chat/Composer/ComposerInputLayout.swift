import SwiftUI

struct ComposerInputLayout: Layout {
    let allowsInline: Bool
    let minimumInlineWidth: CGFloat
    let spacing: CGFloat

    private struct Sizes {
        let leading: CGSize
        let input: CGSize
        let trailing: CGSize
        var actionRowHeight: CGFloat { max(leading.height, trailing.height) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        precondition(subviews.count == 3)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumInlineWidth
        let sizes = sizes(width: width, subviews: subviews)
        return CGSize(width: width, height: inline(width) ? max(sizes.input.height, sizes.actionRowHeight)
                      : sizes.input.height + sizes.actionRowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        precondition(subviews.count == 3)
        let sizes = sizes(width: bounds.width, subviews: subviews)
        let rowMidY = inline(bounds.width) ? bounds.midY : bounds.minY + sizes.input.height + sizes.actionRowHeight / 2
        subviews[0].place(at: CGPoint(x: bounds.minX, y: rowMidY), anchor: .leading, proposal: ProposedViewSize(sizes.leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: rowMidY), anchor: .trailing, proposal: ProposedViewSize(sizes.trailing))
        if inline(bounds.width) {
            subviews[1].place(at: CGPoint(x: bounds.minX + sizes.leading.width + spacing, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(sizes.input))
        } else {
            subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(sizes.input))
        }
    }

    private func inline(_ width: CGFloat) -> Bool { allowsInline && width >= minimumInlineWidth }

    private func sizes(width: CGFloat, subviews: Subviews) -> Sizes {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(ProposedViewSize(width: max(0, width - leading.width), height: nil))
        let inputWidth = inline(width) ? max(0, width - leading.width - trailing.width - spacing * 2) : width
        let input = subviews[1].sizeThatFits(ProposedViewSize(width: inputWidth, height: nil))
        return Sizes(leading: leading, input: CGSize(width: inputWidth, height: input.height), trailing: trailing)
    }
}

struct ComposerSurfaceLayout: Layout {
    let narrows: Bool
    let minimumInlineWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        precondition(subviews.count == 1)
        let surface = subviews[0]
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumInlineWidth
        let size = surface.sizeThatFits(ProposedViewSize(width: width - inset(width) * 2, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        precondition(subviews.count == 1)
        let surface = subviews[0]
        let inset = inset(bounds.width)
        surface.place(at: CGPoint(x: bounds.minX + inset, y: bounds.minY), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width - inset * 2, height: nil))
    }

    private func inset(_ width: CGFloat) -> CGFloat {
        narrows ? min(width * 0.03, max(0, (width - minimumInlineWidth) / 2)) : 0
    }
}
