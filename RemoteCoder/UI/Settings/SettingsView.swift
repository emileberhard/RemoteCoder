import Observation
import SwiftUI

enum SettingsPane: String { case chat, accounts, hosts, automations, location, audio }

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowVisible = true
    @State private var presented = false
    @Environment(\.dismiss) private var dismiss
    @Environment(HostStore.self) private var gatewaySettings

    let workspace: ChatWorkspaceModel
    #if os(iOS)
    @Environment(LiveNavigationSetupController.self) private var liveNavigationSetup
    @State private var page: SettingsPane = .chat
    #else
    @AppStorage(SettingsPane.storageKey) private var page: SettingsPane = .chat
    #endif

    var body: some View {
        TabView(selection: $page.nativeSelectionFeedback()) {
            Tab("Chat", systemImage: "text.bubble", value: SettingsPane.chat) {
                SettingsFormPage {
                    ThemeSettingsSection()
                    #if os(iOS)
                    HapticSettingsSection(models: workspace.newChatModelOptions(preferredHostID: workspace.selectedHostID))
                    #endif
                    NewChatSettingsSection(workspace: workspace)
                    Section {
                        NavigationLink("Licenses") { ThirdPartyLicensesView() }
                    }
                    CodexModelsSettingsSection(catalog: workspace.codexModelCatalog, preferences: workspace.modelPickerPreferences)
                    ClaudeModelsSettingsSection(preferences: workspace.modelPickerPreferences)
                    ReasoningEffortSettingsSection(workspace: workspace)
                    ChatSettingsSection(workspace: workspace)
                    Section {
                        NavigationLink("Licenses") { ThirdPartyLicensesView() }
                    }
                }
            }

            Tab("Accounts", systemImage: "person.crop.circle", value: SettingsPane.accounts) {
                SettingsAccountsPage(workspace: workspace)
            }
            Tab("Hosts", systemImage: "server.rack", value: SettingsPane.hosts) {
                GatewayHostsSettings(settings: gatewaySettings, workspace: workspace) { hosts in
                    SettingsFormPage {
                        hosts
                        DiagnosticsSettingsSection()
                    }
                }
            }

            Tab("Automations", systemImage: "clock.arrow.circlepath", value: SettingsPane.automations) {
                AutomationsAuthorityView(workspace: workspace)
                    .environment(workspace.automationDrafts)
                    .environment(\.automationSurfaceVisible, presented && windowVisible && scenePhase == .active && page == .automations)
                    .environment(\.automationConversationOpener, { route in
                        let address = try await workspace.prepareAutomationConversation(route)
                        guard workspace.switchConversation(to: address) != .refusedWhileDictating else { return false }
                        dismiss()
                        return true
                    })
            }

            #if os(iOS)
            Tab("Location", systemImage: "location.fill", value: SettingsPane.location) {
                SettingsFormPage {
                    if gatewaySettings.localConfiguration.googleMapsAPIKey?.isEmpty == false {
                    LiveNavigationSettingsSection(setup: liveNavigationSetup, gatewayPolicy: workspace.gatewayPolicy, pushTokens: workspace.pushTokens, googleMapsAPIKey: gatewaySettings.localConfiguration.googleMapsAPIKey ?? "")
                    } else {
                        ContentUnavailableView("Navigation unavailable", systemImage: "location.slash")
                    }
                }
            }
            #endif

            Tab("Audio", systemImage: "waveform", value: SettingsPane.audio) {
                SettingsFormPage {
                    #if os(iOS)
                    RealtimeVoiceSettingsSection(workspace: workspace)
                    #endif
                    TranscriptionSettingsSection(settings: workspace.transcriptionSettings, library: workspace.dictationLibrary)
                }
            }
        }
        .settingsTabsChrome()
        .modifier(WindowVisibility(isVisible: $windowVisible))
        .onAppear { presented = true }
        .onDisappear { presented = false }
    }
}
