import SwiftUI
import UIKit

struct ShimmerEffect: ViewModifier {
    let isActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.transcriptRowVisibility) private var rowVisibility

    func body(content: Content) -> some View {
        content.overlay {
            if isActive, contrast != .increased, energyPolicy.animatesDecorations(
                sceneActive: scenePhase == .active,
                visible: visualsVisible && (rowVisibility?.isVisible ?? true),
                reduceMotion: reduceMotion
            ) {
                ShimmerBand()
                    .mask { content.foregroundStyle(.white) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
        }
    }
}

private struct ShimmerBand: UIViewRepresentable {
    func makeUIView(context: Context) -> ShimmerBandView {
        ShimmerBandView()
    }

    func updateUIView(_ view: ShimmerBandView, context: Context) {
        view.update(
            color: Color.appSystemBackground.resolve(in: context.environment),
            direction: context.environment.layoutDirection
        )
    }
}

private final class ShimmerBandView: UIView {
    private static let period: CFTimeInterval = 1.5
    private let container = CALayer()
    private let band = CAGradientLayer()
    private var color: Color.Resolved?
    private var direction = LayoutDirection.leftToRight
    private var geometrySize = CGSize.zero

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(container)
        container.addSublayer(band)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(color: Color.Resolved, direction: LayoutDirection) {
        if self.color != color {
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let tint = UIColor(cgColor: color.cgColor)
            band.colors = (0..<16).map { index in
                tint.withAlphaComponent(0.8 * pow(sin(Double(index) * 0.2), 10)).cgColor
            }
            CATransaction.commit()
        }
        if self.direction != direction {
            self.direction = direction
            geometrySize = .zero
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != geometrySize else { return }
        geometrySize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else {
            stop()
            return
        }
        let angle = atan2(bounds.height, bounds.width)
        let width = hypot(bounds.width, bounds.height)
        let height = bounds.width * sin(angle) + bounds.height * cos(angle)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let mirror = CATransform3DMakeScale(direction == .rightToLeft ? -1 : 1, 1, 1)
        container.transform = CATransform3DRotate(mirror, angle, 0, 0, 1)
        band.bounds = CGRect(x: 0, y: 0, width: width * 2, height: height)
        band.position = CGPoint(x: width / 2, y: height / 2)
        CATransaction.commit()
        animate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
        else { animate() }
    }

    private func stop() {
        band.removeAllAnimations()
    }

    private func animate() {
        guard window != nil, geometrySize.width > 0, geometrySize.height > 0 else { return }
        let movement = CABasicAnimation(keyPath: "transform.translation.x")
        movement.fromValue = -container.bounds.width
        movement.toValue = container.bounds.width
        movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        movement.duration = Self.period
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = (0...45).map { index in
            1 - pow(UnitCurve.easeInOut.value(at: Double(index) / 45), 8)
        }
        opacity.duration = Self.period
        let animation = CAAnimationGroup()
        animation.animations = [movement, opacity]
        animation.duration = Self.period
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        let now = band.convertTime(CACurrentMediaTime(), from: nil)
        animation.beginTime = now - now.truncatingRemainder(dividingBy: Self.period)
        band.add(animation, forKey: "shimmer")
    }
}
