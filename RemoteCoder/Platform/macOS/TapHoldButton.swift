#if os(macOS)
import SwiftUI

struct TapHoldButton: View {
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

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .frame(idealWidth: ControlMetrics.minimumTarget, idealHeight: ControlMetrics.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(ContactStyle(onPressChange: pressChanged))
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier)
        .accessibilityActions {
            if isEnabled {
                ForEach(accessibilityActions.indices, id: \.self) { index in
                    Button(accessibilityActions[index].name, action: accessibilityActions[index].perform)
                }
            }
        }
    }

    private func pressChanged(_ pressing: Bool) {
        onPress(pressing)
        if !pressing { onContactEnded() }
    }

    private struct ContactStyle: ButtonStyle {
        let onPressChange: (Bool) -> Void

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, pressing in onPressChange(pressing) }
        }
    }
}
#endif
