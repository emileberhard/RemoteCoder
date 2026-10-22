import SwiftUI

struct HapticSettingsSection: View {
    let models: [ModelOption]
    @Bindable private var haptics = HapticService.shared

    var body: some View {
        Section {
            Toggle("App haptics", isOn: $haptics.isEnabled)
                .accessibilityIdentifier("app-haptics-enabled")
            HapticStrengthPicker()
                .disabled(!haptics.isEnabled)
            NavigationLink {
                HapticPreviewView(models: models)
            } label: {
                Label("Try feedback", systemImage: "hand.tap")
            }
            .appButtonFeedback()
            .disabled(!haptics.isEnabled)
            .accessibilityIdentifier("app-haptics-preview")
        } header: {
            Text("Touch feedback")
        } footer: {
            Text("Strong adds firmer presses, crisp slider detents and short lift and seating accents. App feedback pauses during dictation and voice calls. System controls and notifications follow their own settings.")
        }
    }
}

private struct HapticStrengthPicker: View {
    @Bindable private var haptics = HapticService.shared

    var body: some View {
        Picker("Feedback strength", selection: $haptics.strength) {
            ForEach(HapticStrength.allCases) { strength in
                Text(strength.title).tag(strength)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("app-haptics-strength")
    }
}

/// These are the production components with local values. No request, upload,
/// clipboard write or conversation preference is changed by trying them.
private struct HapticPreviewView: View {
    @Bindable private var haptics = HapticService.shared
    let models: [ModelOption]
    @State private var sampleChoice = "Image"
    @State private var model: ModelOption?
    @State private var reasoning: ReasoningSelection = .automatic
    @State private var fastMode: Bool? = false
    @State private var accepted = 0

    init(models: [ModelOption]) {
        self.models = models
        _model = State(initialValue: models.first(where: \.supportsFastMode) ?? models.first)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HapticStrengthPicker()
                GroupBox("Press and choose") {
                    HStack(spacing: 24) {
                        Button("Press", systemImage: "hand.tap") {}
                            .appButtonFeedback()
                        AppMenu(trigger: .icon) {
                            Picker("Attachment type", selection: $sampleChoice.nativeSelectionFeedback()) {
                                Text("Image").tag("Image")
                                Text("File").tag("File")
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Try attachment menu")
                        Text(sampleChoice).scaledFont(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                }
                if let selectedModel = model {
                    GroupBox("Hold, slide and release") {
                        VStack(alignment: .leading, spacing: 12) {
                            ConversationSettingsControls(models: models, model: Binding(get: { selectedModel }, set: { model = $0 }),
                                reasoning: $reasoning, fastMode: $fastMode) { EmptyView() }
                            Text("Hold the effort gauge, move through its levels, then release. Or tap to open it first.")
                                .scaledFont(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GroupBox("Acceptance") {
                    VStack(spacing: 12) {
                        Button("Accept sample", systemImage: "checkmark") {
                            accepted += 1
                            haptics.play(.commit)
                        }
                        .buttonStyle(.appGlassActionFeedback)
                        Text("Accepted \(accepted) times")
                            .scaledFont(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88)
                }
                if !haptics.canPlay {
                    Text("App feedback is unavailable or paused. Enable App haptics and end any dictation or voice call; a haptics-capable iPhone is required.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Try feedback")
        .inlineNavigationTitle()
        .reasoningPickerOverlay()
        .onChange(of: model) {
            guard let model else { return }
            if let effort = reasoning.effort, !model.reasoningEfforts.contains(effort) {
                reasoning = .automatic
            }
            if !model.supportsFastMode { fastMode = false }
        }
    }
}
