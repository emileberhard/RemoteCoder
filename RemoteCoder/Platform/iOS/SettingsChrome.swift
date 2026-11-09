import SwiftUI

struct SettingsView: View {
    let workspace: ChatWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HostStore.self) private var hosts
    @Environment(LiveNavigationSetupController.self) private var liveNavigationSetup

    private var googleMapsAPIKey: String? {
        hosts.localConfiguration.googleMapsAPIKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        NavigationStack {
            SettingsPage(title: "Settings") {
                Section {
                    NavigationLink { HostsSettingsPage(workspace: workspace) } label: {
                        LabeledContent {
                            Text(hosts.activeHost?.displayName ?? "")
                        } label: {
                            SettingsTileLabel(title: "Hosts", systemImage: "server.rack", tint: .blue)
                        }
                    }
                    NavigationLink { AccountsOverviewView(workspace: workspace) } label: {
                        SettingsTileLabel(title: "Accounts & Usage", systemImage: "person.crop.circle.fill", tint: .green)
                    }
                    NavigationLink {
                        AutomationsSettingsPage(workspace: workspace, isVisible: scenePhase == .active, dismissSettings: dismiss)
                    } label: {
                        SettingsTileLabel(title: "Automations", systemImage: "clock.arrow.circlepath", tint: .orange)
                    }
                }
                ChatSettingsSection(workspace: workspace)
                ModelsInPickersSection(workspace: workspace)
                Section {
                    NavigationLink { VoiceSettingsPage(workspace: workspace) } label: {
                        SettingsTileLabel(title: "Voice & Dictation", systemImage: "waveform", tint: .pink)
                    }
                    if let googleMapsAPIKey {
                        NavigationLink {
                            SettingsPage(title: "Live Location") {
                                LiveNavigationSettingsSection(setup: liveNavigationSetup, gatewayPolicy: workspace.gatewayPolicy,
                                                              pushTokens: workspace.pushTokens, googleMapsAPIKey: googleMapsAPIKey)
                            }
                        } label: {
                            SettingsTileLabel(title: "Live Location", systemImage: "location.fill", tint: .indigo)
                        }
                    }
                }
                AboutSettingsSection()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        HapticService.shared.play(.disclosure)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsTileLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.gradient, in: .rect(cornerRadius: size * 0.26, style: .continuous))
        }
    }
}

extension View {
    func accountsOverviewPresentation(isPresented: Binding<Bool>, workspace: ChatWorkspaceModel) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                AccountsOverviewView(workspace: workspace)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { isPresented.wrappedValue = false }
                        }
                    }
            }
        }
    }
}
