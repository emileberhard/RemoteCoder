import SwiftUI

struct ComposerSendButton: View {
    let state: ComposerSendState
    let action: () -> Void
    let queue: (() -> Void)?
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible

    var body: some View {
        control
            .disabled(!state.canSend)
            .tooltip(LocalizedStringKey(state.accessibilityLabel))
            .accessibilityLabel(state.accessibilityLabel)
            .accessibilityHint(state == .steer ? "Adds guidance to the current turn without stopping it." : "")
            .accessibilityIdentifier("codex-composer-send")
    }

    @ViewBuilder
    private var control: some View {
        if let queue {
            AppMenu(trigger: .icon) {
                Button(action: action) {
                    Label("Steer", systemImage: "arrow.turn.down.right")
                }
                Button(action: queue) {
                    Label("Queue", systemImage: "text.badge.plus")
                }
            } label: {
                glyph
            } primaryAction: {
                action()
            }
            .menuIndicator(.hidden)
            .accessibilityAction(named: "Queue message", queue)
        } else {
            Button(action: action) { glyph }
                .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.92, pressedOpacity: 0.9))
        }
    }

    private var glyph: some View {
        Group {
            if state == .working && energyPolicy.animatesDecorations(sceneActive: scenePhase == .active,
                visible: visualsVisible, reduceMotion: reduceMotion) {
                ProgressView()
                    .controlSize(ComposerMetrics.workingIndicatorSize)
                    .tint(.primary)
            } else {
                Image(systemName: state == .working ? "ellipsis" : "arrow.up")
                    .scaledFont(.system(size: ComposerMetrics.sendGlyphSize, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
        }
        .foregroundStyle(foreground)
        .scaledFrame(width: ComposerMetrics.actionDiameter, height: ComposerMetrics.actionDiameter)
        .background(state.canSend ? themeStore.theme.colors.accentTint : .primary.opacity(0.06), in: .circle)
        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
        .contentShape(.circle)
    }

    private var foreground: Color {
        state.canSend ? themeStore.theme.filledAccentForeground(for: colorScheme)
            : (state == .working ? .primary : .secondary)
    }
}

struct ComposerStopButton: View {
    let state: ComposerStopState
    let stop: (RunningTurn) -> Void

    var body: some View {
        SlideToConfirmButton(label: state == .stopping ? "Stopping" : "Stop", verb: "stop", symbol: "stop.fill",
                             tint: .red, identifier: "codex-composer-stop") {
            if case .ready(let turn) = state { stop(turn) }
        } face: {
            Image(systemName: "stop.fill")
                .scaledFont(.system(size: ComposerMetrics.stopGlyphSize, weight: .semibold))
                .foregroundStyle(state == .stopping ? .secondary : .primary)
                .scaledFrame(width: ComposerMetrics.actionDiameter, height: ComposerMetrics.actionDiameter)
                .background(.primary.opacity(0.06), in: .circle)
                .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                .contentShape(.circle)
        }
        .disabled(state == .stopping)
        .tooltip(state == .stopping ? "Stopping" : "Stop")
    }
}
