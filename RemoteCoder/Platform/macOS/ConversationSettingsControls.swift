#if os(macOS)
import SwiftUI

struct ConversationSettingsControls<Status: View>: View {
    let models: [ModelOption]
    @Binding var model: ModelOption
    @Binding var reasoning: ReasoningSelection
    @Binding var fastMode: Bool?
    @ViewBuilder var status: Status

    @Environment(ModelPickerPreferences.self) private var preferences
    private let symbolHeight: CGFloat = 15

    private var availableEfforts: [ReasoningEffort] {
        preferences.reasoningEfforts(for: model)
    }

    var body: some View {
        HStack(spacing: 4) {
            ConversationModelMenu(models: models, selection: $model)
                .menuIndicator(.hidden)
                .fixedSize()
                .tooltip("Model")
                .composerControlHitRegion()
            status
            Spacer(minLength: 0)
            reasoningMenu
            ConversationFastModeToggle(isAvailable: model.supportsFastMode, isOn: $fastMode,
                                       symbolHeight: symbolHeight)
                .tooltip("Fast mode")
                .composerControlHitRegion()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningMenu: some View {
        AppMenu {
            Picker("Reasoning Effort", selection: $reasoning.nativeSelectionFeedback()) {
                ForEach(ReasoningSelection.choices(among: availableEfforts)) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                ReasoningEffortIndicator(
                    position: ReasoningGaugePosition(efforts: availableEfforts, selection: reasoning),
                    height: symbolHeight
                )
                Text(reasoning.label)
                Image(systemName: "chevron.down")
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .scaledFont(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(minHeight: ControlMetrics.minimumTarget)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.primary)
        .disabled(availableEfforts.isEmpty)
        .tooltip("Reasoning effort")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(reasoning.label)
        .accessibilityIdentifier("conversation-reasoning-control")
        .composerControlHitRegion()
    }
}
#endif
