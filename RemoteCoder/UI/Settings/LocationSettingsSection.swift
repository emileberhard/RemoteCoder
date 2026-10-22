import SwiftUI

struct LiveNavigationSettingsSection: View {
    @Bindable var setup: LiveNavigationSetupController
    let gatewayPolicy: SharedGatewayPolicy
    let pushTokens: PushTokenSources
    let googleMapsAPIKey: String

    var body: some View {
        Section {
            LabeledContent("Location access", value: setup.authorization)
            LabeledContent("Accuracy", value: setup.accuracy)
            LabeledContent("Google terms", value: setup.googleStatus.map { $0.termsAccepted ? "Accepted" : "Not accepted" } ?? "Loading…")

            Button {
                HapticService.shared.play(.buttonPress)
                Task { await setup.prepare(policy: gatewayPolicy, googleMapsAPIKey: googleMapsAPIKey, pushTokens: pushTokens) }
            } label: {
                HStack {
                    Label("Prepare live location", systemImage: "location.circle")
                    if setup.isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(setup.isWorking)

            Text(setup.status)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)

            if let errorMessage = setup.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Live location")
        }
        .task { setup.refreshGoogleStatus() }

        Section {
            if let googleStatus = setup.googleStatus {
                NavigationLink("Licenses") {
                    GoogleNavigationLicensesView(status: googleStatus)
                }
            }
        } header: {
            Text("Google Maps")
        } footer: {
            Text("Navigation data powered by Google Maps.")
        }
    }
}

struct GoogleNavigationLicensesView: View {
    let status: LiveNavigationSetupController.GoogleStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabeledContent("Navigation SDK", value: status.sdkVersion)
                Text(status.openSourceLicenses)
                    .scaledFont(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Google licenses")
        .inlineNavigationTitle()
    }
}
