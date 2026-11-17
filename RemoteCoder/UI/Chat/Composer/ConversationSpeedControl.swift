import SwiftUI

struct ConversationSpeedControl: View {
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contactID = UUID()
    @State private var isPressed = false

    let model: ModelOption
    @Binding var speed: ConversationSpeed?
    let symbolHeight: CGFloat
    var haptics: HapticService = .shared

    private var available: Bool { model.supportsFastMode || model.supportsUltrafast || ultrafast }
    private var ultrafast: Bool { speed == .ultrafast }
    private var useMotion: Bool { !reduceMotion && scenePhase == .active }
    private var value: String { available ? (speed?.label ?? "Unknown") : "Unavailable" }

    private var animation: Animation? {
        guard useMotion else { return nil }
        return ultrafast ? .linear(duration: 0.62) : .easeOut(duration: 0.15)
    }

    var body: some View {
        control
            .opacity(available ? 1 : 0.35)
            .disabled(!available)
            .onChange(of: isEnabled) { if !isEnabled { cancelContact() } }
            .onChange(of: scenePhase) { if scenePhase != .active { cancelContact() } }
            .onChange(of: model) { cancelContact() }
            .onDisappear { cancelContact() }
    }

    @ViewBuilder
    private var control: some View {
        if model.supportsUltrafast {
            #if os(iOS)
            artwork
                .accessibilityHidden(true)
                .overlay {
                    TapHoldButton(label: "Speed", value: value, hint: "Tap for Fast. Hold for Ultrafast.",
                        identifier: "conversation-fast-mode-toggle", accessibilityActions: choices,
                        onPress: press, onContactEnded: endContact, onTap: tap,
                        onHold: { phase, _, _ in
                            if phase == .began { hold() }
                        })
                }
            #else
            artwork
                .gesture(LongPressGesture(minimumDuration: 0.28, maximumDistance: 12)
                    .exclusively(before: TapGesture()).onEnded {
                        switch $0 {
                        case .first: hold()
                        case .second: tap()
                        }
                    })
                .focusable()
                .onKeyPress(.space) {
                    tap()
                    return .handled
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Speed")
                .accessibilityValue(value)
                .accessibilityIdentifier("conversation-fast-mode-toggle")
                .accessibilityAction { tap() }
                .accessibilityActions {
                    ForEach(ConversationSpeed.allCases, id: \.self) { speed in
                        if model.supportsSpeed(speed) {
                            Button(speed.label) { select(speed) }
                        }
                    }
                }
            #endif
        } else {
            Button(action: tap) { artwork }
                .buttonStyle(ResponsiveButtonStyle(feedback: nil))
                .accessibilityLabel(ultrafast ? "Speed" : "Fast mode")
                .accessibilityValue(value)
                .accessibilityIdentifier("conversation-fast-mode-toggle")
        }
    }

    private var artwork: some View {
        let colors = themeStore.theme.colors
        return JetstreamBolt(
            phase: ultrafast ? 1 : 0, side: symbolHeight,
            boltColor: speed?.isAccelerated == true && available ? colors.accentTint : .secondary,
            jetstreamColor: colors.highlight)
            .animation(animation, value: ultrafast)
            .overlay(alignment: .topTrailing) {
                if available, speed == nil {
                    Text("?").scaledFont(.caption2.bold()).offset(x: 8, y: -3)
                }
            }
            .scaleEffect(isPressed && useMotion ? 0.945 : 1)
            .animation(useMotion ? AppControlMotion.press(isPressed) : nil, value: isPressed)
            .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
            .contentShape(.rect)
    }

    private var choices: [TapHoldButton.AccessibilityAction] {
        ConversationSpeed.allCases.filter(model.supportsSpeed).map { choice in
            .init(name: choice.label) { select(choice) }
        }
    }

    private func tap() {
        if speed == .fast || (ultrafast && !model.supportsFastMode) {
            select(.standard)
        } else {
            select(.fast)
        }
    }

    private func hold() {
        select(ultrafast ? (model.supportsFastMode ? .fast : .standard) : .ultrafast)
    }

    private func select(_ choice: ConversationSpeed) {
        guard available, isEnabled, scenePhase == .active, model.supportsSpeed(choice), speed != choice else { return }
        if choice == .ultrafast {
            haptics.beginInteraction(owner: contactID)
            haptics.playInteraction(.speedBoost, owner: contactID)
            haptics.finishInteraction(owner: contactID)
        } else {
            haptics.play(choice == .fast && !ultrafast ? .toggleOn : .toggleOff)
        }
        isPressed = false
        speed = choice
    }

    private func press(_ pressed: Bool) {
        isPressed = pressed
        if pressed, !ultrafast, isEnabled, scenePhase == .active {
            haptics.beginInteraction(owner: contactID)
        }
    }

    private func endContact() {
        isPressed = false
        haptics.finishInteraction(owner: contactID)
    }

    private func cancelContact() {
        isPressed = false
        haptics.cancelInteraction(owner: contactID)
    }
}

private struct JetstreamBolt: View, Animatable {
    @Environment(\.layoutDirection) private var layoutDirection
    var phase: CGFloat
    let side: CGFloat
    let boltColor: Color
    let jetstreamColor: Color

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }

    var body: some View {
        let reveal = progress(from: 0, to: 0.15)
        let rush = eased(from: 0.06, to: 0.26) * (1 - eased(from: 0.26, to: 0.77))
        let arrival = eased(from: 0.08, to: 0.74)
        ZStack {
            bolt(size: side)
                .foregroundStyle(boltColor)
                .opacity(1 - reveal)
            ZStack {
                VStack(alignment: .trailing, spacing: 2.9) {
                    dash(0.52 + 0.32 * rush, opacity: 0.85)
                    dash(0.36 + 0.31 * rush, opacity: 0.62)
                    dash(0.21 + 0.24 * rush, opacity: 0.40)
                }
                .offset(x: direction * side * (-0.49 - (1 - arrival) * 0.25), y: side * 0.06)
                .opacity(arrival)
                bolt(size: side * 0.99)
                    .offset(x: direction * side * (0.25 + 0.16 * rush))
                    .scaleEffect(x: 1 + 0.12 * rush, y: 1 - 0.08 * rush)
            }
            .foregroundStyle(jetstreamColor)
            .opacity(reveal)
        }
        .frame(width: side, height: side)
    }

    private func bolt(size: CGFloat) -> some View {
        Image(systemName: "bolt.fill")
            .resizable()
            .symbolRenderingMode(.monochrome)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func dash(_ width: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(.foreground.opacity(opacity))
            .frame(width: width * side, height: 1.5)
    }

    private func progress(from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(1, max(0, (phase - start) / (end - start)))
    }

    private func eased(from start: CGFloat, to end: CGFloat) -> CGFloat {
        let progress = progress(from: start, to: end)
        return progress * progress * (3 - 2 * progress)
    }
}
