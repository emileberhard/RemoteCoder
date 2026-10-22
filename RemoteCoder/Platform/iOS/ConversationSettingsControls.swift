import SwiftUI

// Chat and Voice Mode share controls; the screen owns their floating picker.
struct ConversationSettingsControls<Status: View>: View {
    let models: [ModelOption]
    @Binding var model: ModelOption
    @Binding var reasoning: ReasoningSelection
    @Binding var fastMode: Bool?
    var haptics: HapticService = .shared
    @ViewBuilder var status: Status

    @Environment(ReasoningPickerPresentation.self) private var picker
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var symbolHeight = 22.0
    @Environment(ModelPickerPreferences.self) private var preferences
    @State private var ownerID = UUID()
    @State private var rowFrame: CGRect = .zero
    @State private var gaugeFrame: CGRect = .zero
    @State private var isReasoningPressed = false
    @State private var heldSession: ReasoningPickerPresentation.Session?
    @State private var gaugeChange: ReasoningGaugeChange?
    @State private var gaugePosition: ReasoningGaugePosition?

    private var availableEfforts: [ReasoningEffort] {
        preferences.reasoningEfforts(for: model)
    }

    private var gaugeChangeReadyToSettle: ReasoningGaugeChange? {
        picker.presentedSession?.owner == ownerID ? nil : gaugeChange
    }

    var body: some View {
        controls
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // Layout can move when a settings warning or error appears.
                // Only a live gesture has coordinates to invalidate; a committed gauge
                // adjustment must survive that expected composer reflow.
                if rowFrame != frame, picker.session?.owner == ownerID {
                    picker.dismiss(owner: ownerID)
                    cancelGaugeFeedback()
                }
                rowFrame = frame
            }
            .onChange(of: model) {
                picker.dismiss(owner: ownerID)
                cancelGaugeFeedback()
            }
            .onChange(of: reasoning) {
                picker.dismiss(owner: ownerID)
                if gaugeChange?.selection != reasoning { cancelGaugeFeedback() }
            }
            .onChange(of: isEnabled) {
                if !isEnabled {
                    picker.dismiss(owner: ownerID)
                    cancelGaugeFeedback()
                }
            }
            .onChange(of: scenePhase) { if scenePhase != .active { cancelGaugeFeedback() } }
            .onChange(of: reduceMotion) { cancelGaugeFeedback() }
            .onChange(of: availableEfforts) {
                picker.dismiss(owner: ownerID)
                cancelGaugeFeedback()
            }
            .onDisappear {
                picker.dismiss(owner: ownerID)
                cancelGaugeFeedback()
            }
            .task(id: gaugeChangeReadyToSettle) {
                if let change = gaugeChangeReadyToSettle { await settleGauge(change) }
            }
            .onChange(of: picker.presentedSession?.id) {
                finishContactIfIdle()
            }
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedControls
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    modelControls
                    Spacer(minLength: 0)
                    optionControls
                }
                stackedControls
            }
        }
    }

    private var stackedControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelControls
            optionControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var optionControls: some View {
        HStack(spacing: 0) {
            status
            reasoningControl
            fastModeToggle
        }
    }

    private var modelControls: some View {
        ConversationModelMenu(models: models, selection: $model)
            .composerControlHitRegion()
    }

    private var reasoningControl: some View {
        ReasoningEffortIndicator(
            position: gaugePosition ?? ReasoningGaugePosition(efforts: availableEfforts, selection: reasoning),
            height: symbolHeight
        )
            // Measure the glyph, not its larger touch target or the finger.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gaugeFrame = $0 }
            .opacity(picker.presentedSession?.owner == ownerID ? 0 : 1)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHidden(true)
            .overlay {
                ReasoningActivationSurface(
                    value: reasoning.label,
                    onPress: { pressed in
                        isReasoningPressed = pressed
                        if pressed {
                            cancelGaugeFeedback()
                            haptics.beginInteraction(owner: ownerID)
                        }
                    },
                    onContactEnded: finishContactIfIdle,
                    onTap: { _ = openPicker(held: false) },
                    onHold: handleHold
                )
            }
            .scaleEffect(isReasoningPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : AppControlMotion.press(isReasoningPressed), value: isReasoningPressed)
            .appPressFeedback(.sliderGrab, isPressed: isReasoningPressed)
            .composerControlHitRegion()
            .disabled(availableEfforts.isEmpty)
    }

    private var fastModeToggle: some View {
        ConversationFastModeToggle(isAvailable: model.supportsFastMode, isOn: $fastMode, symbolHeight: symbolHeight)
            .composerControlHitRegion()
    }

    private func openPicker(held: Bool) -> ReasoningPickerPresentation.Session? {
        guard isEnabled, scenePhase == .active else { return nil }
        gaugeChange = nil
        gaugePosition = nil
        haptics.beginInteraction(owner: ownerID)
        let initialModel = model
        let initialReasoning = reasoning
        let initialEfforts = availableEfforts
        return picker.present(
            owner: ownerID, model: model, efforts: initialEfforts, selection: reasoning, source: gaugeFrame,
            held: held, isRightToLeft: layoutDirection == .rightToLeft
        ) { selected in
            guard isEnabled, scenePhase == .active,
                  model == initialModel, reasoning == initialReasoning,
                  let feedback = ReasoningGaugeFeedback(from: initialReasoning, to: selected,
                      efforts: initialEfforts) else { return }
            gaugePosition = ReasoningGaugePosition(efforts: initialEfforts, selection: initialReasoning)
            gaugeChange = ReasoningGaugeChange(selection: selected, feedback: feedback)
            reasoning = selected
        }
    }

    private func cancelGaugeFeedback() {
        gaugeChange = nil
        gaugePosition = nil
        haptics.cancelInteraction(owner: ownerID)
    }

    private func finishContactIfIdle() {
        if picker.presentedSession?.owner != ownerID, gaugeChange == nil {
            haptics.cancelInteraction(owner: ownerID)
        }
    }

    private func settleGauge(_ change: ReasoningGaugeChange) async {
        guard !Task.isCancelled, isCurrentGaugeChange(change) else { return }
        let target = ReasoningGaugePosition(efforts: availableEfforts, selection: change.selection)
        if reduceMotion {
            gaugePosition = target
            haptics.playInteraction(.sliderSettle, owner: ownerID)
            completeGaugeSettle(change)
            return
        }

        // Start as soon as the picker has returned; the first tick accompanies motion.
        let clock = ContinuousClock()
        let started = clock.now
        withAnimation(.spring(duration: change.feedback.animationDuration, bounce: 0.12)) {
            gaugePosition = target
        }
        await change.feedback.play(
            isCurrent: { isCurrentGaugeChange(change) },
            waitForTick: { offset in
                let deadline = started.advanced(by: offset)
                try await clock.sleep(until: deadline, tolerance: .milliseconds(4))
                return clock.now < deadline.advanced(by: .milliseconds(40))
            },
            feedback: { haptics.playInteraction($0, owner: ownerID) }
        )
        // Playback owns cleanup: an animation with no interpolated change (for
        // example Automatic to the top level) must not cut the tick sequence short.
        completeGaugeSettle(change)
    }

    private func isCurrentGaugeChange(_ change: ReasoningGaugeChange) -> Bool {
        gaugeChange == change && scenePhase == .active && isEnabled &&
            reasoning == change.selection && picker.presentedSession == nil
    }

    private func completeGaugeSettle(_ change: ReasoningGaugeChange) {
        guard isCurrentGaugeChange(change) else { return }
        haptics.finishInteraction(owner: ownerID)
        gaugeChange = nil
    }

    private func handleHold(_ phase: TapHoldPhase, _ location: CGPoint) {
        switch phase {
        case .began:
            heldSession = openPicker(held: true)
            heldSession?.updateHold(at: location)
        case .changed:
            heldSession?.updateHold(at: location)
        case .ended:
            guard let session = heldSession else { return }
            heldSession = nil
            picker.finish(session, at: location)
        case .cancelled:
            guard let session = heldSession else { return }
            heldSession = nil
            picker.dismiss(owner: session.owner)
        }
    }
}

private struct ReasoningGaugeChange: Equatable {
    let id = UUID()
    let selection: ReasoningSelection
    let feedback: ReasoningGaugeFeedback
}
