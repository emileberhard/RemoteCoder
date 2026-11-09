import SwiftUI

struct ClaudeModelsSettingsRow: View {
    let hostEntries: [CodexModelCatalog.Entry]
    let preferences: ModelPickerPreferences

    private var shownCount: Int {
        ClaudeModelCatalog.models.filter { preferences.claudeModelVisibility.isVisible(id: $0.id) }.count
            + hostEntries.filter(preferences.codexModelVisibility.isVisible).count
    }

    var body: some View {
        NavigationLink {
            ClaudeModelsSettingsPage(hostEntries: hostEntries, preferences: preferences)
        } label: {
            ProviderSettingsLabel(provider: .claude,
                                  value: "\(shownCount) of \(ClaudeModelCatalog.models.count + hostEntries.count)")
        }
        .accessibilityIdentifier("claude-models-settings")
    }
}

private struct ClaudeModelsSettingsPage: View {
    let hostEntries: [CodexModelCatalog.Entry]
    let preferences: ModelPickerPreferences

    var body: some View {
        SettingsPage(title: "Claude Code") {
            Section {
                ForEach(ClaudeModelCatalog.models) { model in
                    Toggle(model.displayName, isOn: Binding(
                        get: { preferences.claudeModelVisibility.isVisible(id: model.id) },
                        set: { preferences.setClaudeModelVisible($0, id: model.id) }
                    ))
                    .accessibilityIdentifier("claude-model-visible-\(model.id)")
                }
            } header: {
                Text("Shown in Pickers")
            } footer: {
                Text("New models appear automatically. Conversations keep their model even when you hide it.")
            }
            HostModelsSection(entries: hostEntries, header: "From the Host",
                              footer: "Claude models the host offers through other providers.", preferences: preferences)
            ReasoningLevelsSection(provider: .claude, models: ClaudeModelCatalog.models + hostEntries.map(\.option),
                                   preferences: preferences)
        }
    }
}
