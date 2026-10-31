import SwiftUI

struct InlineMarkdownText: View {
    let text: AttributedString
    let reveal: [StreamingRevealSpan]
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.siteIcons) private var siteIcons

    var body: some View {
        let chips = LinkChipSpan.spans(in: text)
        Group {
            if chips.isEmpty {
                Text(text)
            } else {
                let pointSize = (font ?? .body).resolve(in: fontContext).pointSize
                let hosts = Set(chips.compactMap(\.iconHost))
                Self.composed(text, chips: chips, pointSize: pointSize)
                    .textRenderer(LinkChipRenderer(icons: chips.map(icon), pointSize: pointSize))
                    .task(id: hosts) {
                        do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                        siteIcons?.request(hosts)
                    }
            }
        }
        .streamingRevealCovers(reveal.isEmpty ? nil : StreamingRevealLayoutMap(
            text: text, spans: reveal, replacements: chips.map { $0.replacement(in: text) }))
        .animation(nil, value: chips.isEmpty)
    }

    private func icon(for chip: LinkChipSpan) -> LinkChipIcon {
        switch chip.style.chip {
        case .web(let host): .site(host.flatMap { siteIcons?.icon(for: $0).image })
        case .file(let symbol): .symbol(symbol)
        case .mail: .symbol("envelope")
        case .phone: .symbol("phone")
        case .other: .symbol("link")
        }
    }

    private static func composed(_ text: AttributedString, chips: [LinkChipSpan], pointSize: CGFloat) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: chips.count * 3 + 1)
        var cursor = text.startIndex
        for (index, chip) in chips.enumerated() {
            if cursor < chip.range.lowerBound {
                interpolation.appendInterpolation(Text(AttributedString(text[cursor..<chip.range.lowerBound])))
            }
            var slot = AttributedString(LinkChipSpan.slot)
            slot.link = chip.url
            slot.kern = pointSize * LinkChipRenderer.slotKern
            var label = chip.style.shortLabel.map(AttributedString.init) ?? AttributedString(text[chip.range])
            label.link = chip.url
            if let last = label.characters.indices.last {
                label[last..<label.endIndex].kern = pointSize * LinkChipRenderer.trailingPadding
            }
            interpolation.appendInterpolation(Text(slot).customAttribute(LinkChipMark(index: index, isSlot: true)))
            interpolation.appendInterpolation(Text(label).fontWeight(.semibold).textScale(.secondary).customAttribute(LinkChipMark(index: index, isSlot: false)))
            cursor = chip.range.upperBound
        }
        if cursor < text.endIndex {
            interpolation.appendInterpolation(Text(AttributedString(text[cursor..<text.endIndex])))
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation))
    }
}

private struct LinkChipSpan {
    static let slot = "\u{00A0}"

    let range: Range<AttributedString.Index>
    let url: URL
    let style: LinkChipStyle

    var iconHost: String? {
        if case .web(let host) = style.chip { host } else { nil }
    }

    func replacement(in text: AttributedString) -> StreamingRevealLayoutMap.Replacement {
        let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let source = start..<(start + text.utf16.distance(from: range.lowerBound, to: range.upperBound))
        return .init(source: source, length: Self.slot.utf16.count + (style.shortLabel?.utf16.count ?? source.count))
    }

    static func spans(in text: AttributedString) -> [LinkChipSpan] {
        text.runs[AttributeScopes.FoundationAttributes.LinkAttribute.self, LinkChipAttribute.self].compactMap { url, style, range in
            guard let url, let style else { return nil }
            return LinkChipSpan(range: range, url: url, style: style)
        }
    }
}

private struct LinkChipMark: TextAttribute {
    let index: Int
    let isSlot: Bool
}

private enum LinkChipIcon {
    case site(Image?)
    case symbol(String)
}

private struct LinkChipRenderer: TextRenderer {
    static let leadingPadding: CGFloat = 0.3
    static let iconSize: CGFloat = 0.85
    static let iconGap: CGFloat = 0.28
    static let trailingPadding: CGFloat = 0.42
    static let slotKern = leadingPadding + iconSize + iconGap - 0.25

    let icons: [LinkChipIcon]
    let pointSize: CGFloat

    var displayPadding: EdgeInsets { EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let fill = Color.primary.opacity(context.environment.colorScheme == .dark ? 0.13 : 0.07)
        for line in layout {
            var chip: (index: Int, rect: CGRect)?
            for run in line {
                guard let mark = run[LinkChipMark.self] else {
                    capsule(chip?.rect, fill: fill, in: &context)
                    chip = nil
                    continue
                }
                let rect = run.typographicBounds.rect
                if let open = chip, open.index == mark.index {
                    chip = (open.index, open.rect.union(rect))
                } else {
                    capsule(chip?.rect, fill: fill, in: &context)
                    chip = (mark.index, rect)
                }
            }
            capsule(chip?.rect, fill: fill, in: &context)
        }
        for line in layout {
            context.draw(line)
        }
        for line in layout {
            for run in line {
                guard let mark = run[LinkChipMark.self], mark.isSlot, icons.indices.contains(mark.index) else { continue }
                draw(icons[mark.index], slot: run.typographicBounds.rect, in: &context)
            }
        }
    }

    private func capsule(_ rect: CGRect?, fill: Color, in context: inout GraphicsContext) {
        guard let rect else { return }
        let band = rect.insetBy(dx: 0, dy: 1)
        context.fill(Path(roundedRect: band, cornerRadius: band.height / 2), with: .color(fill))
    }

    private func draw(_ icon: LinkChipIcon, slot: CGRect, in context: inout GraphicsContext) {
        let side = min(pointSize * Self.iconSize, slot.height - 2)
        let frame = CGRect(x: slot.minX + pointSize * Self.leadingPadding, y: slot.midY - side / 2, width: side, height: side)
        switch icon {
        case .site(let image?):
            let plate = Path(roundedRect: frame, cornerRadius: side * 0.24)
            context.fill(plate, with: .color(.white))
            var clipped = context
            clipped.clip(to: plate)
            clipped.draw(image, in: frame)
        case .site(nil):
            symbol("globe", in: frame, context: &context)
        case .symbol(let name):
            symbol(name, in: frame, context: &context)
        }
    }

    private func symbol(_ name: String, in frame: CGRect, context: inout GraphicsContext) {
        let glyph = context.resolve(Text(Image(systemName: name)).fontWeight(.semibold).foregroundStyle(.tint))
        let width = glyph.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
        let scale = min(1, frame.width / max(width, 1))
        var fitted = context
        fitted.translateBy(x: frame.midX, y: frame.midY)
        fitted.scaleBy(x: scale, y: scale)
        fitted.draw(glyph, at: .zero)
    }
}
