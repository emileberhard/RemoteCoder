import SwiftUI
import UIKit

/// UIKit owns both paths: short touches activate the button; a recognized
/// long press cancels button tracking and continues through move/end/cancel.
/// The SwiftUI label still owns sizing and appearance.
struct ReasoningActivationSurface: UIViewRepresentable {
    let value: String
    let onPress: (Bool) -> Void
    let onContactEnded: () -> Void
    let onTap: () -> Void
    let onHold: (TapHoldPhase, CGPoint) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onHold: onHold)
    }

    func makeUIView(context: Context) -> PressTrackingButton {
        let button = PressTrackingButton(type: .custom)
        button.onPress = onPress
        button.onContactEnded = onContactEnded
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .primaryActionTriggered)
        button.addGestureRecognizer(context.coordinator.hold)
        button.accessibilityLabel = "Reasoning effort"
        button.accessibilityHint = "Opens the slider. You can also hold, slide, and release to choose."
        button.accessibilityIdentifier = "conversation-reasoning-control"
        return button
    }

    func updateUIView(_ button: PressTrackingButton, context: Context) {
        button.onPress = onPress
        button.onContactEnded = onContactEnded
        context.coordinator.onTap = onTap
        context.coordinator.onHold = onHold
        button.accessibilityValue = value
        button.isEnabled = isEnabled
        context.coordinator.hold.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PressTrackingButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 44, height: 44))
    }

    static func dismantleUIView(_ button: PressTrackingButton, coordinator: Coordinator) {
        button.onPress(false)
        button.onPress = { _ in }
        button.onContactEnded = {}
        coordinator.hold.isEnabled = false
        coordinator.cancelHold()
    }

    final class PressTrackingButton: UIButton {
        var onPress: (Bool) -> Void = { _ in }
        var onContactEnded: () -> Void = {}

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            onContactEnded()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            onContactEnded()
        }

        override var isHighlighted: Bool {
            didSet { if oldValue != isHighlighted { onPress(isHighlighted) } }
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onTap: () -> Void
        var onHold: (TapHoldPhase, CGPoint) -> Void
        private var isHolding = false
        lazy var hold: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleHold))
            recognizer.minimumPressDuration = 0.28
            recognizer.allowableMovement = 12
            recognizer.cancelsTouchesInView = true
            return recognizer
        }()

        init(onTap: @escaping () -> Void, onHold: @escaping (TapHoldPhase, CGPoint) -> Void) {
            self.onTap = onTap
            self.onHold = onHold
        }

        @objc func activate() {
            onTap()
        }

        @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            // UIKit window coordinates match the screen overlay's global space.
            isHolding = recognizer.state == .began || recognizer.state == .changed
            guard let phase = TapHoldPhase(recognizer.state) else { return }
            onHold(phase, recognizer.location(in: nil))
        }

        func cancelHold() {
            guard isHolding else { return }
            isHolding = false
            onHold(.cancelled, .zero)
        }
    }
}
