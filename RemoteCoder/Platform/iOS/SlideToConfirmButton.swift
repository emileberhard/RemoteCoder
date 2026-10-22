import SwiftUI
import UIKit

struct SlideToConfirmButton<Face: View>: View {
    let label: String
    let verb: String
    let symbol: String
    let tint: Color
    let identifier: String
    let action: () -> Void
    @ViewBuilder let face: () -> Face

    @State private var phase: SlidePhase = .idle
    @State private var isPressed = false
    @State private var owner = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    private static var travel: CGFloat { SlidePhase.travel }
    private static var flickSpeed: CGFloat { 300 }
    private static var flickDistance: CGFloat { 12 }

    var body: some View {
        face()
            .opacity(phase == .idle ? 1 : 0)
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                if phase != .idle {
                    guide
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .overlay {
                SlideUpControl(label: label, hint: "Swipe up to \(verb).", identifier: identifier,
                               onEvent: handle, onActivate: confirm)
            }
            .zIndex(phase == .idle ? 0 : 1)
            .appPressFeedback(.iconPress, isPressed: isPressed)
            .onChange(of: scenePhase) { if scenePhase != .active { cancel() } }
            .onChange(of: isEnabled) { if !isEnabled { cancel() } }
            .onDisappear { cancel() }
    }

    private var guide: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(phase.isArmed ? "Release to \(verb)" : "Swipe up to \(verb)")
                .scaledFont(.footnote.weight(.semibold))
                .contentTransition(.identity)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .appGlass(.standard, in: .capsule)
                .fixedSize()

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(tint.opacity(phase.isArmed ? 0.3 : 0.08 + 0.14 * phase.progress))
                Image(systemName: "chevron.up")
                    .scaledFont(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(1 - phase.progress)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
                thumb
                    .padding(.bottom, (ControlMetrics.minimumTarget - ComposerMetrics.actionDiameter) / 2)
                    .offset(y: -thumbLift)
            }
            .frame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget + Self.travel)
            .appGlass(.standard, in: .capsule)
        }
    }

    private var thumb: some View {
        Image(systemName: symbol)
            .scaledFont(.system(size: ComposerMetrics.stopGlyphSize + 2, weight: .semibold))
            .foregroundStyle(phase.isArmed ? Color.white : Color.primary)
            .frame(width: ComposerMetrics.actionDiameter, height: ComposerMetrics.actionDiameter)
            .background(phase.isArmed ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.12)), in: .circle)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: phase.isArmed)
    }

    private var thumbLift: CGFloat {
        let lift = phase.progress * Self.travel
        guard case .tracking(let distance, _) = phase, distance > Self.travel else { return lift }
        let overflow = distance - Self.travel
        return Self.travel + overflow / (1 + overflow / 16)
    }

    private func handle(_ event: SlideUpEvent) {
        guard isEnabled, scenePhase == .active else { return cancel() }
        switch event {
        case .contact:
            isPressed = true
            HapticService.shared.beginInteraction(owner: owner)
            settle(to: .tracking(distance: 0, armed: false))
        case .drag(let distance):
            guard phase != .idle else { return }
            let wasArmed = phase.isArmed
            let armed = distance >= Self.travel || (wasArmed && distance >= Self.travel - 8)
            if armed && !wasArmed { HapticService.shared.playInteraction(.sliderMaximum, owner: owner) }
            var transaction = Transaction(animation: nil)
            transaction.isContinuous = true
            withTransaction(transaction) { phase = .tracking(distance: distance, armed: armed) }
        case .release(let distance, let upwardSpeed):
            let flicked = distance >= Self.flickDistance && upwardSpeed >= Self.flickSpeed
            guard phase != .idle, phase.isArmed || flicked else { return cancel() }
            isPressed = false
            HapticService.shared.playInteraction(.commit, owner: owner)
            HapticService.shared.finishInteraction(owner: owner)
            settle(to: .idle)
            action()
        case .cancel:
            cancel()
        }
    }

    private func confirm() {
        guard isEnabled else { return }
        action()
    }

    private func cancel() {
        isPressed = false
        HapticService.shared.cancelInteraction(owner: owner)
        if phase != .idle { settle(to: .idle) }
    }

    private func settle(to next: SlidePhase) {
        withAnimation(reduceMotion ? .smooth(duration: 0.15) : .spring(duration: 0.3, bounce: 0.15)) { phase = next }
    }
}

private enum SlidePhase: Equatable {
    static let travel: CGFloat = 64

    case idle
    case tracking(distance: CGFloat, armed: Bool)

    var isArmed: Bool {
        if case .tracking(_, true) = self { return true }
        return false
    }

    var progress: CGFloat {
        guard case .tracking(let distance, _) = self else { return 0 }
        return min(max(distance / Self.travel, 0), 1)
    }
}

private enum SlideUpEvent {
    case contact
    case drag(CGFloat)
    case release(distance: CGFloat, upwardSpeed: CGFloat)
    case cancel
}

private struct SlideUpControl: UIViewRepresentable {
    let label: String
    let hint: String
    let identifier: String
    let onEvent: (SlideUpEvent) -> Void
    let onActivate: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> Control { Control() }

    func updateUIView(_ control: Control, context: Context) {
        control.onEvent = onEvent
        control.onActivate = onActivate
        control.accessibilityLabel = label
        control.accessibilityHint = hint
        control.accessibilityIdentifier = identifier
        control.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Control, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 44, height: 44))
    }

    static func dismantleUIView(_ control: Control, coordinator: ()) {
        control.onEvent = { _ in }
        control.onActivate = {}
        control.cancelContact()
    }

    final class Control: UIControl {
        var onEvent: (SlideUpEvent) -> Void = { _ in }
        var onActivate: () -> Void = {}
        private var origin: CGPoint?
        private var samples: [(location: CGPoint, time: TimeInterval)] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { return nil }

        override func accessibilityActivate() -> Bool {
            onActivate()
            return true
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let location = touch.location(in: nil)
            origin = location
            samples = [(location, touch.timestamp)]
            onEvent(.contact)
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard let origin else { return false }
            let location = touch.location(in: nil)
            samples.append((location, touch.timestamp))
            if samples.count > 5 { samples.removeFirst(samples.count - 5) }
            onEvent(.drag(origin.y - location.y))
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            defer { reset() }
            guard let origin else { return }
            if let touch { samples.append((touch.location(in: nil), touch.timestamp)) }
            let distance = (samples.last?.location.y).map { origin.y - $0 } ?? 0
            onEvent(.release(distance: distance, upwardSpeed: upwardSpeed))
        }

        override func cancelTracking(with event: UIEvent?) {
            cancelContact()
        }

        func cancelContact() {
            guard origin != nil else { return }
            reset()
            onEvent(.cancel)
        }

        private var upwardSpeed: CGFloat {
            guard let first = samples.first, let last = samples.last, last.time - first.time > 0.004 else { return 0 }
            return (first.location.y - last.location.y) / CGFloat(last.time - first.time)
        }

        private func reset() {
            origin = nil
            samples = []
        }
    }
}
