import SwiftUI

struct ThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(theme.colors.accentTint)
            Circle().fill(theme.colors.highlightSecondary)
        }
        .frame(width: 27, height: 12)
        .accessibilityHidden(true)
    }
}

struct ChatSettingsSection: View {
    let workspace: ChatWorkspaceModel
    @Environment(AppThemeStore.self) private var themeStore
    @AppStorage(NewChatDefaults.modelDefaultKey) private var modelDefault = NewChatDefaults.lastSelectedValue
    @AppStorage(NewChatDefaults.reasoningDefaultKey) private var reasoningDefault = NewChatDefaults.lastSelectedValue

    private var defaultModel: ModelOption? { workspace.newChatDefaultModel().model }
    private var modelOptions: [ModelOption] { workspace.newChatModelOptions(preferredHostID: workspace.selectedHostID) }

    private var reasoningEfforts: [ReasoningEffort] {
        guard let defaultModel else { return [] }
        return workspace.modelPickerPreferences.reasoningEfforts(for: defaultModel)
    }

    private var fixedModelID: String? {
        modelDefault == NewChatDefaults.lastSelectedValue ? nil : ClaudeModelCatalog.canonicalModelID(modelDefault)
    }

    private var unavailableFixedModelName: String? {
        guard let fixedModelID, !modelOptions.contains(where: { $0.id == fixedModelID }) else { return nil }
        return workspace.configuredModel(id: fixedModelID).model?.displayName ?? fixedModelID
    }

    private var modelDefaultBinding: Binding<String> {
        Binding(get: { modelDefault }, set: {
            modelDefault = $0
            workspace.refreshNewChatDefaults()
        })
    }

    private var reasoningDefaultBinding: Binding<String> {
        Binding(get: {
            guard let defaultModel, let selection = ReasoningSelection.fromStorageValue(reasoningDefault) else {
                return reasoningDefault
            }
            return workspace.modelPickerPreferences.clamped(selection, for: defaultModel).id
        }, set: {
            reasoningDefault = $0
            workspace.refreshNewChatDefaults()
        })
    }

    var body: some View {
        @Bindable var themes = themeStore

        Section {
            Picker(selection: $themes.selectedThemeID.nativeSelectionFeedback()) {
                ForEach(AppThemeID.allCases) { themeID in
                    Text(themeID.displayName).tag(themeID)
                }
            } label: {
                HStack(spacing: 10) {
                    ThemeSwatch(theme: themes.theme)
                    Text("Theme")
                }
            }

            Picker("New Chat Model", selection: modelDefaultBinding.nativeSelectionFeedback()) {
                Text("Last Selected").tag(NewChatDefaults.lastSelectedValue)
                ForEach(modelOptions) { option in
                    Text(option.pickerTitle).tag(option.id)
                }
                if let unavailableFixedModelName {
                    Text(unavailableFixedModelName).tag(modelDefault)
                }
            }
            .accessibilityIdentifier("new-chat-default-model")

            Picker("New Chat Reasoning", selection: reasoningDefaultBinding.nativeSelectionFeedback()) {
                Text("Last Selected").tag(NewChatDefaults.lastSelectedValue)
                Text("Automatic").tag(ReasoningSelection.automatic.id)
                ForEach(reasoningEfforts) { effort in
                    Text(effort.label).tag(ReasoningSelection.effort(effort).id)
                }
            }
            .accessibilityIdentifier("new-chat-default-reasoning")
        } header: {
            Text("Chat")
        } footer: {
            if let unavailableFixedModelName {
                Text(defaultModel.map { "\(unavailableFixedModelName) is hidden or unavailable, so new chats use \($0.displayName)." }
                     ?? "\(unavailableFixedModelName) is hidden or unavailable, and no other model is available yet.")
            }
        }
        .drillDownPickerStyle()
    }
}

struct ReasoningLevelsSection: View {
    let provider: AgentProvider
    let models: [ModelOption]
    let preferences: ModelPickerPreferences

    private var supportedEfforts: [ReasoningEffort] {
        let supported = Set(models.flatMap(\.reasoningEfforts))
        return ReasoningEffort.allCases.filter(supported.contains)
    }

    var body: some View {
        if !supportedEfforts.isEmpty {
            Section {
                ForEach(supportedEfforts) { effort in
                    Toggle(effort.label, isOn: Binding(
                        get: { preferences.isVisible(effort, for: provider) },
                        set: { preferences.setVisible(effort, $0, for: provider) }
                    ))
                    .accessibilityIdentifier("visible-reasoning-\(provider.rawValue)-\(effort.rawValue)")
                }
            } header: {
                Text("Reasoning Levels")
            } footer: {
                Text("Hidden selections move to the nearest visible level. Automatic is always available, including when all levels are hidden.")
            }
        }
    }
}
