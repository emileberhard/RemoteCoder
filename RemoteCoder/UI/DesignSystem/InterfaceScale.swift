import SwiftUI

extension View {
    func scaledFont(_ font: Font?) -> some View {
        modifier(ScaledFont(font: font))
    }

    func scaledFrame(width: CGFloat, height: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, alignment: alignment))
    }

    func scaledFrame(maxWidth: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(ScaledMaxWidth(maxWidth: maxWidth, alignment: alignment))
    }
}

@propertyWrapper
struct InterfaceScaledMetric: DynamicProperty {
    @ScaledMetric private var base: CGFloat
    @Environment(\.interfaceScale) private var scale

    init(wrappedValue: CGFloat, relativeTo textStyle: Font.TextStyle) {
        _base = ScaledMetric(wrappedValue: wrappedValue, relativeTo: textStyle)
    }

    var wrappedValue: CGFloat { base * scale }
}

private struct ScaledFont: ViewModifier {
    let font: Font?
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.font(scale == 1 ? font : font?.scaled(by: scale))
    }
}

private struct ScaledFrame: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    let alignment: Alignment
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.frame(width: width * scale, height: height * scale, alignment: alignment)
    }
}

private struct ScaledMaxWidth: ViewModifier {
    let maxWidth: CGFloat
    let alignment: Alignment
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.frame(maxWidth: maxWidth * scale, alignment: alignment)
    }
}
