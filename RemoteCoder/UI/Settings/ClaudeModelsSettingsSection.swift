import SwiftUI

struct ClaudeModelsSettingsSection: View {
    let preferences: ModelPickerPreferences

    private var shownCount: Int {
        ClaudeModelCatalog.models.filter { preferences.claudeModelVisibility.isVisible(id: $0.id) }.count
    }

    var body: some View {
        Section("Claude Code models") {
            NavigationLink {
                ClaudeModelsSettingsPage(preferences: preferences)
            } label: {
                LabeledContent("Models", value: "\(shownCount) of \(ClaudeModelCatalog.models.count) shown")
            }
            .accessibilityIdentifier("claude-models-settings")
        }
    }
}

private struct ClaudeModelsSettingsPage: View {
    let preferences: ModelPickerPreferences

    var body: some View {
        Form {
            Section {
                ForEach(ClaudeModelCatalog.models) { model in
                    Toggle(model.displayName, isOn: Binding(
                        get: { preferences.claudeModelVisibility.isVisible(id: model.id) },
                        set: { preferences.setClaudeModelVisible($0, id: model.id) }
                    ))
                    .accessibilityIdentifier("claude-model-visible-\(model.id)")
                }
            } header: {
                Text("Shown in pickers")
            } footer: {
                Text("New models appear automatically. Conversations keep their model even when you hide it.")
            }
        }
        .navigationTitle("Claude Code Models")
        .inlineNavigationTitle()
    }
}
