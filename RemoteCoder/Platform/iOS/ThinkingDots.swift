import SwiftUI
import UIKit

struct ThinkingDots: View {
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        Text("...")
            .foregroundStyle(tint)
            .opacity(isAnimating ? 0 : 1)
            .overlay {
                if isAnimating {
                    SteppingDots(tint: tint)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct SteppingDots: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> SteppingDotsView {
        SteppingDotsView()
    }

    func updateUIView(_ view: SteppingDotsView, context: Context) {
        let font = (context.environment.font ?? .body).resolve(in: context.environment.fontResolutionContext)
        view.update(color: UIColor(cgColor: tint.resolve(in: context.environment).cgColor),
                    font: UIFont.systemFont(ofSize: font.pointSize))
    }
}

private final class SteppingDotsView: UIView {
    private static let step: CFTimeInterval = 0.28
    private let dots = (0..<3).map { _ in CALayer() }
    private var font = UIFont.systemFont(ofSize: UIFont.systemFontSize)

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        dots.forEach(layer.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(color: UIColor, font: UIFont) {
        dots.forEach { $0.backgroundColor = color.cgColor }
        guard font != self.font else { return }
        self.font = font
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = (font.pointSize * 0.14).rounded(.up)
        let advance = bounds.width / CGFloat(dots.count)
        let baseline = bounds.height + font.descender
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: advance * (CGFloat(index) + 0.5) - diameter / 2, y: baseline - diameter,
                               width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            guard window != nil else { continue }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.calculationMode = .discrete
            animation.values = (0..<4).map { step in step > index ? 1 : 0.25 }
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = Self.step * 4
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            dot.add(animation, forKey: "step")
        }
    }
}
