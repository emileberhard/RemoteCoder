#if os(macOS)
import SwiftUI

extension SettingsPane {
    static let storageKey = "settings.selectedPane"
}

struct SettingsFormPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            Form { content }
                .formStyle(.grouped)
        }
    }
}

struct SettingsAccountsPage: View {
    let workspace: ChatWorkspaceModel

    var body: some View {
        NavigationStack {
            AccountsOverviewView(workspace: workspace)
        }
    }
}

extension View {
    func settingsTabsChrome() -> some View {
        frame(width: 640)
            .frame(minHeight: 440, idealHeight: 560)
    }

    func accountsOverviewPresentation(isPresented: Binding<Bool>, workspace: ChatWorkspaceModel) -> some View {
        modifier(AccountsSettingsPaneOpener(isPresented: isPresented))
    }
}

private struct AccountsSettingsPaneOpener: ViewModifier {
    @Binding var isPresented: Bool
    @AppStorage(SettingsPane.storageKey) private var pane: SettingsPane = .chat
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
