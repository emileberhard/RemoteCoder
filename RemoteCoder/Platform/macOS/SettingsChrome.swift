#if os(macOS)
import SwiftUI

enum SettingsPane: String {
    case general, keyboard, accounts, hosts, automations, dictation

    static let storageKey = "settings.selectedPane"
}

struct SettingsView: View {
    let workspace: ChatWorkspaceModel
    @AppStorage(SettingsPane.storageKey) private var pane: SettingsPane = .general
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowVisible = true
    @State private var presented = false

    var body: some View {
        TabView(selection: $pane.nativeSelectionFeedback()) {
            Tab("General", systemImage: "gearshape", value: SettingsPane.general) {
                NavigationStack {
                    SettingsPage(title: "General") {
                        ChatSettingsSection(workspace: workspace)
                        ModelsInPickersSection(workspace: workspace)
                        AboutSettingsSection()
                    }
                }
            }
            Tab("Keyboard", systemImage: "keyboard", value: SettingsPane.keyboard) {
                NavigationStack { KeyboardShortcutsSettings() }
            }
            Tab("Accounts", systemImage: "person.crop.circle", value: SettingsPane.accounts) {
                NavigationStack { AccountsOverviewView(workspace: workspace) }
            }
            Tab("Hosts", systemImage: "server.rack", value: SettingsPane.hosts) {
                NavigationStack { HostsSettingsPage(workspace: workspace) }
            }
            Tab("Automations", systemImage: "clock.arrow.circlepath", value: SettingsPane.automations) {
                NavigationStack {
                    AutomationsSettingsPage(
                        workspace: workspace,
                        isVisible: presented && windowVisible && scenePhase == .active && pane == .automations,
                        dismissSettings: dismiss)
                }
            }
            Tab("Dictation", systemImage: "waveform", value: SettingsPane.dictation) {
                NavigationStack { VoiceSettingsPage(workspace: workspace) }
            }
        }
        .frame(width: 640)
        .frame(minHeight: 440, idealHeight: 560)
        .modifier(WindowVisibility(isVisible: $windowVisible))
        .onAppear { presented = true }
        .onDisappear { presented = false }
    }
}

extension View {
    func accountsOverviewPresentation(isPresented: Binding<Bool>, workspace: ChatWorkspaceModel) -> some View {
        modifier(AccountsSettingsPaneOpener(isPresented: isPresented))
    }
}

private struct AccountsSettingsPaneOpener: ViewModifier {
    @Binding var isPresented: Bool
    @AppStorage(SettingsPane.storageKey) private var pane: SettingsPane = .general
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { _, presented in
            guard presented else { return }
            pane = .accounts
            openSettings()
            isPresented = false
        }
    }
}
#endif
