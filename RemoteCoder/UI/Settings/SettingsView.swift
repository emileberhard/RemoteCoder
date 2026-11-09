import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(title)
            .inlineNavigationTitle()
    }
}

struct HostsSettingsPage: View {
    let workspace: ChatWorkspaceModel
    @Environment(HostStore.self) private var hosts

    var body: some View {
        GatewayHostsSettings(settings: hosts, workspace: workspace) { gateways in
            SettingsPage(title: "Hosts") {
                gateways
                Section {
                    NavigationLink("Cluster") { ClusterSettingsView(workspace: workspace) }
                }
            }
        }
    }
}

struct AutomationsSettingsPage: View {
    let workspace: ChatWorkspaceModel
    let isVisible: Bool
    let dismissSettings: DismissAction

    var body: some View {
        AutomationsAuthorityView(workspace: workspace)
            .environment(workspace.automationDrafts)
            .environment(\.automationSurfaceVisible, isVisible)
            .environment(\.automationConversationOpener, { route in
                let address = try await workspace.prepareAutomationConversation(route)
                guard workspace.switchConversation(to: address) != .refusedWhileDictating else { return false }
                dismissSettings()
                return true
            })
    }
}

struct VoiceSettingsPage: View {
    let workspace: ChatWorkspaceModel

    var body: some View {
        #if os(iOS)
        SettingsPage(title: "Voice & Dictation") {
            RealtimeVoiceSettingsSection(workspace: workspace)
            TranscriptionSettingsSection(settings: workspace.transcriptionSettings, library: workspace.dictationLibrary)
        }
        #else
        SettingsPage(title: "Dictation") {
            TranscriptionSettingsSection(settings: workspace.transcriptionSettings, library: workspace.dictationLibrary)
        }
        #endif
    }
}

struct ModelsInPickersSection: View {
    let workspace: ChatWorkspaceModel

    var body: some View {
        Section("Models in Pickers") {
            CodexModelsSettingsRow(catalog: workspace.codexModelCatalog, preferences: workspace.modelPickerPreferences)
            ClaudeModelsSettingsRow(hostEntries: workspace.codexModelCatalog.source?.service.catalog?.entries
                                        .filter { $0.option.provider == .claude } ?? [],
                                    preferences: workspace.modelPickerPreferences)
        }
    }
}

struct ProviderSettingsLabel: View {
    let provider: AgentProvider
    let value: String
    @InterfaceScaledMetric(relativeTo: .body) private var markSize: CGFloat = 20

    var body: some View {
        LabeledContent {
            Text(value)
        } label: {
            Label {
                Text(provider.settingsTitle)
            } icon: {
                Image(provider.markImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(provider.markStyle)
                    .frame(width: markSize, height: markSize)
            }
        }
    }
}

extension AgentProvider {
    var settingsTitle: String { self == .claude ? "Claude Code" : "Codex" }
}
