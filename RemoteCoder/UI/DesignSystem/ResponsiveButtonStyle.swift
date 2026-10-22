import SwiftUI

/// Native Button owns activation and cancellation; this style never installs a recognizer.
struct ResponsiveButtonStyle: ButtonStyle {
    var feedback: HapticEvent? = .buttonPress
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.9

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, feedback: feedback,
             pressedScale: pressedScale, pressedOpacity: pressedOpacity)
    }

    private struct PressBody: View {
        let configuration: ButtonStyle.Configuration
        let feedback: HapticEvent?
        let pressedScale: CGFloat
        let pressedOpacity: Double
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? pressedScale : 1)
                .opacity(configuration.isPressed && isEnabled ? pressedOpacity : 1)
                .animation(reduceMotion ? nil : AppControlMotion.press(configuration.isPressed), value: configuration.isPressed)
                .appPressFeedback(feedback, isPressed: configuration.isPressed)
        }
    }
}
