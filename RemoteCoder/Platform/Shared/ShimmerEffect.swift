import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ShimmerEffect: ViewModifier {
    let isActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.surfaceVisibility) private var surfaceVisibility
    @Environment(\.transcriptRowVisibility) private var rowVisibility

    func body(content: Content) -> some View {
        content.overlay {
            if isActive, contrast != .increased, energyPolicy.animatesDecorations(
                sceneActive: scenePhase == .active,
                visible: surfaceVisibility.isVisible && (rowVisibility?.isVisible ?? true),
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

#if os(macOS)
private struct ShimmerBand: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView() }

    func updateNSView(_ view: ShimmerBandView, context: Context) {
        view.shimmer.update(
            color: Color.appSystemBackground.resolve(in: context.environment),
            direction: context.environment.layoutDirection,
            size: view.bounds.size
        )
    }

    static func dismantleNSView(_ view: ShimmerBandView, coordinator: ()) { view.stop() }
}

private final class ShimmerBandView: NSView {
    let shimmer = ShimmerBandLayers()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let root = CALayer()
        root.addSublayer(shimmer.container)
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        shimmer.layout(size: bounds.size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification, object: window)
        }
        visibilityChanged()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        shimmer.setVisible(false)
    }

    @objc private func visibilityChanged() {
        shimmer.setVisible(window?.occlusionState.contains(.visible) == true)
    }

    @objc private func windowWillClose() { shimmer.setVisible(false) }
}
#else
private struct ShimmerBand: UIViewRepresentable {
    func makeUIView(context: Context) -> ShimmerBandView { ShimmerBandView() }

    func updateUIView(_ view: ShimmerBandView, context: Context) {
        view.shimmer.update(
            color: Color.appSystemBackground.resolve(in: context.environment),
            direction: context.environment.layoutDirection,
            size: view.bounds.size
        )
    }

    static func dismantleUIView(_ view: ShimmerBandView, coordinator: ()) { view.shimmer.setVisible(false) }
}

private final class ShimmerBandView: UIView {
    let shimmer = ShimmerBandLayers()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(shimmer.container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmer.layout(size: bounds.size)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        shimmer.setVisible(window != nil)
    }
}
#endif

@MainActor
private final class ShimmerBandLayers {
    private static let period: CFTimeInterval = 1.5
    let container = CALayer()
    private let band = CAGradientLayer()
    private var color: Color.Resolved?
    private var direction = LayoutDirection.leftToRight
    private var geometrySize = CGSize.zero
    private var isVisible = false

    init() {
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        container.addSublayer(band)
    }

    func update(color: Color.Resolved, direction: LayoutDirection, size: CGSize) {
        if self.color != color {
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.colors = (0..<16).map { index in
                guard let tint = color.cgColor.copy(alpha: 0.8 * pow(sin(Double(index) * 0.2), 10)) else {
                    preconditionFailure("Shimmer tint does not support alpha")
                }
                return tint
            }
            CATransaction.commit()
        }
        if self.direction != direction {
            self.direction = direction
            geometrySize = .zero
        }
        layout(size: size)
    }

    func layout(size: CGSize) {
        guard size != geometrySize else { return }
        geometrySize = size
        let bounds = CGRect(origin: .zero, size: size)
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

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { animate() }
        else { stop() }
    }

    private func stop() {
        band.removeAllAnimations()
    }

    private func animate() {
        guard isVisible, geometrySize.width > 0, geometrySize.height > 0 else { return }
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
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        let now = band.convertTime(CACurrentMediaTime(), from: nil)
        animation.beginTime = now - now.truncatingRemainder(dividingBy: Self.period)
        band.add(animation, forKey: "shimmer")
    }
}
