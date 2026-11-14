import SwiftUI

enum QuickDictationRelease: Equatable {
    case sends, edits
}

enum QuickDictationPhase: Equatable {
    case held(QuickDictationRelease)
    case sending, unsent

    var isHeld: Bool {
        if case .held = self { true } else { false }
    }

    var linger: Duration? {
        switch self {
        case .held: nil
        case .sending: .seconds(1.5)
        case .unsent: .seconds(1.2)
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .held(.sends): "Release to send"
        case .held(.edits): "Release to edit"
        case .sending: "Sending…"
        case .unsent: "Not sent"
        }
    }

    var shortHint: LocalizedStringKey {
        switch self {
        case .held(.sends): "Send"
        case .held(.edits): "Edit"
        case .sending: "Sending…"
        case .unsent: "Not sent"
        }
    }

    var tint: Color {
        switch self {
        case .held(.sends), .sending: .composerRecording
        case .held(.edits), .unsent: Color(white: 0.42)
        }
    }
}

struct ComposerDictationButton: View {
    let isTranscribing: Bool
    let phase: QuickDictationPhase?
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onHoldMoved: (QuickDictationRelease) -> Void
    let onRelease: (QuickDictationRelease) -> Void

    @State private var isPressed = false
    @State private var sendZone = CGRect.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    private static let sendReach: CGFloat = 48

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if phase?.isHeld == true { return 1.3 }
        return isPressed ? 0.96 : 1
    }

    var body: some View {
        face
            .accessibilityHidden(true)
            .overlay {
                TapHoldButton(label: isTranscribing ? "Transcribing recording" : "Start recording", value: nil,
                              hint: "Double-tap and hold to dictate, then lift to send.", identifier: "composer-dictate",
                              accessibilityActions: [], onPress: pressChanged, onContactEnded: {},
                              onTap: onTap, onHold: holdChanged)
                    .disabled(phase?.isHeld == false)
            }
            .animation(reduceMotion ? .smooth(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2), value: phase)
            .disabled(isTranscribing && phase == nil)
            .tooltip(isTranscribing ? "Transcribing recording" : "Dictate")
    }

    private var face: some View {
        ZStack {
            if let phase {
                Circle()
                    .fill(phase.tint)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
            if isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(phase == nil ? nil : .white)
            } else {
                glyph
                    .foregroundStyle(.primary)
                    .opacity(phase == nil ? 1 : 0)
                glyph
                    .foregroundStyle(.white)
                    .opacity(phase == nil ? 0 : 1)
            }
        }
        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
        .contentShape(.rect)
        .scaleEffect(scale)
        .opacity(isPressed && phase == nil ? 0.9 : 1)
        .animation(reduceMotion ? nil : AppControlMotion.press(isPressed), value: isPressed)
    }

    private var glyph: some View {
        Image(systemName: "mic")
            .symbolRenderingMode(.monochrome)
            .scaledFont(.system(size: ComposerMetrics.iconSize))
    }

    private func pressChanged(_ pressed: Bool) {
        isPressed = pressed
        if pressed, isEnabled, scenePhase == .active { HapticService.shared.play(.iconPress) }
    }

    private func release(at location: CGPoint) -> QuickDictationRelease {
        sendZone.contains(location) ? .sends : .edits
    }

    private func holdChanged(_ phase: TapHoldPhase, _ location: CGPoint, _ source: CGRect) {
        switch phase {
        case .began:
            guard isEnabled, scenePhase == .active else { return }
            sendZone = source.insetBy(dx: -Self.sendReach, dy: -Self.sendReach)
            HapticService.shared.play(.toggleOn)
            onHoldBegan()
        case .changed:
            onHoldMoved(release(at: location))
        case .ended:
            onRelease(release(at: location))
        case .cancelled:
            onRelease(.edits)
        }
    }
}
