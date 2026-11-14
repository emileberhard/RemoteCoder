import SwiftUI

enum QuickDictationRelease: Equatable {
    case sends, keepsDraft

    var hint: LocalizedStringKey {
        switch self {
        case .sends: "Release to send"
        case .keepsDraft: "Release to keep draft"
        }
    }

    var tint: Color {
        switch self {
        case .sends: .composerRecording
        case .keepsDraft: .gray
        }
    }
}

extension Color {
    static let composerRecording = Color(red: 0.85, green: 0.20, blue: 0.20)
}

struct ComposerDictationButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    @Binding var release: QuickDictationRelease?
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onRelease: (QuickDictationRelease) -> Void

    @State private var isPressed = false
    @State private var sendZone = CGRect.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    private static var sendReach: CGFloat { 48 }

    private var held: QuickDictationRelease? { isRecording ? release : nil }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if held != nil { return 1.3 }
        return isPressed ? 0.96 : 1
    }

    var body: some View {
        face
            .accessibilityHidden(true)
            .overlay(alignment: .topTrailing) {
                if let held {
                    Text(held.hint)
                        .scaledFont(.footnote.weight(.semibold))
                        .contentTransition(.identity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .appGlass(.standard, in: .capsule)
                        .fixedSize()
                        .alignmentGuide(.top) { $0[.bottom] + 18 }
                        .alignmentGuide(.trailing) { $0[.trailing] - ControlMetrics.minimumTarget }
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .overlay {
                TapHoldButton(label: isTranscribing ? "Transcribing recording" : "Start recording", value: nil,
                              hint: "Hold to dictate and send when you let go.", identifier: "composer-dictate",
                              accessibilityActions: [], onPress: pressChanged, onContactEnded: {},
                              onTap: onTap, onHold: holdChanged)
            }
            .zIndex(held == nil ? 0 : 1)
            .animation(reduceMotion ? .smooth(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2), value: held)
            .disabled(isTranscribing)
            .tooltip(isTranscribing ? "Transcribing recording" : "Dictate")
    }

    private var face: some View {
        ZStack {
            if let held {
                Circle()
                    .fill(held.tint)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if isTranscribing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: held == nil ? "mic" : "mic.fill")
                    .symbolRenderingMode(.monochrome)
                    .scaledFont(.system(size: ComposerMetrics.iconSize))
                    .foregroundStyle(held == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            }
        }
        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
        .contentShape(.rect)
        .scaleEffect(scale)
        .opacity(isPressed && held == nil ? 0.9 : 1)
        .animation(reduceMotion ? nil : AppControlMotion.press(isPressed), value: isPressed)
    }

    private func pressChanged(_ pressed: Bool) {
        isPressed = pressed
        if pressed, isEnabled, scenePhase == .active { HapticService.shared.play(.iconPress) }
    }

    private func holdChanged(_ phase: TapHoldPhase, _ location: CGPoint, _ source: CGRect) {
        switch phase {
        case .began:
            guard isEnabled, scenePhase == .active else { return }
            sendZone = source.insetBy(dx: -Self.sendReach, dy: -Self.sendReach)
            HapticService.shared.play(.toggleOn)
            onHoldBegan()
        case .changed:
            guard release != nil else { return }
            let next: QuickDictationRelease = sendZone.contains(location) ? .sends : .keepsDraft
            if release != next { release = next }
        case .ended:
            if let release { onRelease(release) }
        case .cancelled:
            if release != nil { onRelease(.keepsDraft) }
        }
    }
}
