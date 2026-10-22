import SwiftUI

struct SettingsFormPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .inlineNavigationTitle()
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

struct SettingsAccountsPage: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: ChatWorkspaceModel

    var body: some View {
        NavigationStack {
            AccountsOverviewView(workspace: workspace)
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

extension View {
    func settingsTabsChrome() -> some View {
        tabViewStyle(.sidebarAdaptable)
    }

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
