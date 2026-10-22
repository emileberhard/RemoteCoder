import QuartzCore
import SwiftUI
import UIKit

struct ConversationDrawer<Content: View, Sidebar: View>: View {
    @Binding private var isOpen: Bool
    private let onBeginOpening: () -> Void
    private let content: Content
    private let sidebar: Sidebar

    @State private var motion: DrawerMotion
    @State private var committedOpen: Bool
    @State private var releaseCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    init(
        isOpen: Binding<Bool>,
        onBeginOpening: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder sidebar: () -> Sidebar
    ) {
        _isOpen = isOpen
        self.onBeginOpening = onBeginOpening
        self.content = content()
        self.sidebar = sidebar()
        _motion = State(initialValue: DrawerMotion(isOpen: isOpen.wrappedValue))
        _committedOpen = State(initialValue: isOpen.wrappedValue)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(330, max(288, geometry.size.width * 0.76), max(0, geometry.size.width - 44))
            let progress = motion.progress

            ZStack(alignment: .leading) {
                sidebar
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: pixelAligned(-(reduceMotion ? width : 24) * (1 - progress)))
                    .accessibilityHidden(!isOpen)
                    .accessibilityAction(.escape) { isOpen = false }

                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(isOpen)
                    .overlay { dismissalSurface(coverage: progress) }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2)) { surface in
                        surface.clipShape(DrawerSurfaceShape(cornerRadius: progress > 0 ? 32 : 0, safeArea: geometry.safeAreaInsets))
                    }
                    .offset(x: pixelAligned(width * progress))
            }
            .gesture(DrawerPanGesture(
                canMove: { translation in translation * direction > 0 ? motion.progress < 1 : motion.progress > 0 },
                onBegan: beginDragging,
                onChanged: { translation in motion.track(by: translation * direction / max(width, 1)) },
                onEnded: { velocity in endDragging(velocity: velocity * direction / max(width, 1)) }
            ))
        }
        .background { ThemedSheetBackground() }
        .appGestureFeedback(.disclosure, trigger: releaseCount)
        .onChange(of: isOpen) { _, open in
            guard open != committedOpen else { return }
            committedOpen = open
            motion.move(open: open, animated: !reduceMotion)
        }
    }

    private func dismissalSurface(coverage: CGFloat) -> some View {
        Button {
            isOpen = false
        } label: {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.16))
                .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 1, pressedOpacity: 1))
        .accessibilityLabel("Close conversations")
        .accessibilityIdentifier("close-conversations")
        .accessibilityHidden(!isOpen)
        .allowsHitTesting(isOpen)
        .opacity(coverage)
        .ignoresSafeArea()
    }

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }

    private func pixelAligned(_ distance: CGFloat) -> CGFloat {
        (distance * displayScale).rounded() / displayScale
    }

    private func beginDragging() {
        motion.beginTracking()
        guard !committedOpen else { return }
        committedOpen = true
        onBeginOpening()
        isOpen = true
    }

    private func endDragging(velocity: CGFloat) {
        guard let open = motion.release(velocity: velocity) else { return }
        releaseCount += 1
        committedOpen = open
        isOpen = open
    }
}

@MainActor
@Observable
final class DrawerMotion {
    private(set) var progress: CGFloat

    @ObservationIgnored private var dragOrigin: CGFloat?
    @ObservationIgnored private var target: CGFloat
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var frameTimestamp: CFTimeInterval?

    private static let spring = Spring(duration: 0.2, bounce: 0)
    private static let releaseProjectionSeconds: CGFloat = 0.3

    init(isOpen: Bool) {
        let resting: CGFloat = isOpen ? 1 : 0
        progress = resting
        target = resting
    }

    static func restsOpen(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress + velocity * releaseProjectionSeconds > 0.5
    }

    func beginTracking() {
        stopSettling()
        dragOrigin = progress
    }

    func track(by translation: CGFloat) {
        guard let dragOrigin else { return }
        progress = min(max(dragOrigin + translation, 0), 1)
    }

    func release(velocity: CGFloat) -> Bool? {
        guard dragOrigin != nil else { return nil }
        dragOrigin = nil
        let open = Self.restsOpen(progress: progress, velocity: velocity)
        settle(open: open, velocity: velocity)
        return open
    }

    func move(open: Bool, animated: Bool) {
        dragOrigin = nil
        if animated {
            settle(open: open, velocity: displayLink == nil ? 0 : velocity)
        } else {
            stopSettling()
            progress = open ? 1 : 0
            target = progress
        }
    }

    fileprivate func advance(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp - (frameTimestamp ?? link.timestamp)
        frameTimestamp = link.targetTimestamp
        var value = progress
        var nextVelocity = velocity
        Self.spring.update(value: &value, velocity: &nextVelocity, target: target, deltaTime: elapsed)
        let reachedTarget = (value - target) * (progress - target) <= 0
        let atRest = abs(value - target) < 0.001 && abs(nextVelocity) < 0.05
        if reachedTarget || atRest {
            stopSettling()
            progress = target
        } else {
            progress = value
            velocity = nextVelocity
        }
    }

    private func settle(open: Bool, velocity: CGFloat) {
        target = open ? 1 : 0
        self.velocity = velocity
        guard progress != target else {
            stopSettling()
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DrawerFrameTarget(motion: self), selector: #selector(DrawerFrameTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopSettling() {
        displayLink?.invalidate()
        displayLink = nil
        frameTimestamp = nil
        velocity = 0
    }
}

@MainActor
private final class DrawerFrameTarget: NSObject {
    private weak var motion: DrawerMotion?

    init(motion: DrawerMotion) {
        self.motion = motion
    }

    @objc func step(_ link: CADisplayLink) {
        guard let motion else {
            link.invalidate()
            return
        }
        motion.advance(link)
    }
}

private struct DrawerPanGesture: UIGestureRecognizerRepresentable {
    let canMove: (CGFloat) -> Bool
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, canMove: canMove)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.canMove = canMove
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            onBegan()
            if let translation = context.converter.localTranslation { onChanged(translation.x) }
        case .changed:
            if let translation = context.converter.localTranslation { onChanged(translation.x) }
        case .ended:
            onEnded(context.converter.localVelocity?.x ?? 0)
        case .cancelled:
            onEnded(0)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let converter: CoordinateSpaceConverter
        var canMove: (CGFloat) -> Bool

        init(converter: CoordinateSpaceConverter, canMove: @escaping (CGFloat) -> Bool) {
            self.converter = converter
            self.canMove = canMove
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let translation = converter.localTranslation, abs(translation.x) > abs(translation.y) else { return false }
            return canMove(translation.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            Self.scrollAxis(of: other) == .horizontal
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            Self.scrollAxis(of: other) == .vertical
        }

        private static func scrollAxis(of recognizer: UIGestureRecognizer) -> Axis? {
            guard let scrollView = recognizer.view as? UIScrollView, recognizer === scrollView.panGestureRecognizer else { return nil }
            let insets = scrollView.adjustedContentInset
            let overflowsHorizontally = scrollView.contentSize.width + insets.left + insets.right > scrollView.bounds.width
            return scrollView.alwaysBounceHorizontal || overflowsHorizontally ? .horizontal : .vertical
        }
    }
}

private struct DrawerSurfaceShape: Shape {
    var cornerRadius: CGFloat
    let safeArea: EdgeInsets

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bounds = CGRect(
            x: rect.minX,
            y: rect.minY - safeArea.top,
            width: rect.width,
            height: rect.height + safeArea.top + safeArea.bottom
        )
        return Path(roundedRect: bounds, cornerRadius: cornerRadius, style: .continuous)
    }
}
