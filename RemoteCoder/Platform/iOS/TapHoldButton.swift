import SwiftUI
import UIKit

/// One UIKit touch owner for a tap and a hold: a recognized hold cancels the button's
/// tracking, so release never also taps, and tracking continues outside the control.
struct TapHoldButton: UIViewRepresentable {
    let label: String
    let value: String?
    let hint: String
    let identifier: String
    let accessibilityActions: [AccessibilityAction]
    let onPress: (Bool) -> Void
    let onContactEnded: () -> Void
    let onTap: () -> Void
    let onHold: (TapHoldPhase, CGPoint, CGRect) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onHold: onHold) }

    func makeUIView(context: Context) -> ContactButton {
        let button = ContactButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .primaryActionTriggered)
        button.addGestureRecognizer(context.coordinator.hold)
        return button
    }

    func updateUIView(_ button: ContactButton, context: Context) {
        button.onPress = onPress
        button.onContactEnded = onContactEnded
        context.coordinator.onTap = onTap
        context.coordinator.onHold = onHold
        button.accessibilityLabel = label
        button.accessibilityValue = value
        button.accessibilityHint = hint
        button.accessibilityIdentifier = identifier
        button.accessibilityCustomActions = isEnabled ? accessibilityActions.map { action in
            UIAccessibilityCustomAction(name: action.name) { _ in
                action.perform()
                return true
            }
        } : []
        button.isEnabled = isEnabled
        context.coordinator.hold.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContactButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 44, height: 44))
    }

    static func dismantleUIView(_ button: ContactButton, coordinator: Coordinator) {
        coordinator.cancelHold()
        button.onContactEnded()
        button.onPress = { _ in }
        button.onContactEnded = {}
        button.accessibilityCustomActions = []
        coordinator.onTap = {}
        coordinator.onHold = { _, _, _ in }
        coordinator.hold.isEnabled = false
    }

    final class ContactButton: UIButton {
        var onPress: (Bool) -> Void = { _ in }
        var onContactEnded: () -> Void = {}

        override var isHighlighted: Bool {
            didSet { if oldValue != isHighlighted { onPress(isHighlighted) } }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            onContactEnded()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            onContactEnded()
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onTap: () -> Void
        var onHold: (TapHoldPhase, CGPoint, CGRect) -> Void
        private var isHolding = false
        lazy var hold: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(track))
            recognizer.minimumPressDuration = 0.28
            recognizer.allowableMovement = 12
            recognizer.cancelsTouchesInView = true
            return recognizer
        }()

        init(onTap: @escaping () -> Void, onHold: @escaping (TapHoldPhase, CGPoint, CGRect) -> Void) {
            self.onTap = onTap
            self.onHold = onHold
        }

        @objc func activate() { if !isHolding { onTap() } }

        @objc private func track(_ recognizer: UILongPressGestureRecognizer) {
            isHolding = recognizer.state == .began || recognizer.state == .changed
            guard let phase = TapHoldPhase(recognizer.state) else { return }
            let source: CGRect
            if phase == .began, let view = recognizer.view {
                source = view.convert(view.bounds, to: nil)
            } else {
                source = .zero
            }
            onHold(phase, recognizer.location(in: nil), source)
        }

        func cancelHold() {
            guard isHolding else { return }
            isHolding = false
            onHold(.cancelled, .zero, .zero)
        }
    }
}

extension TapHoldPhase {
    init?(_ state: UIGestureRecognizer.State) {
        switch state {
        case .began: self = .began
        case .changed: self = .changed
        case .ended: self = .ended
        case .cancelled, .failed: self = .cancelled
        case .possible: return nil
        @unknown default: return nil
        }
    }
}
