import Foundation

/// Physical-host resources belong to its chat target.
@MainActor
final class HostServices {
    let routes: GatewayRoutes
    let speech: GatewaySpeechAccess
    let files: HostFileStore
    let htmlVisualDocuments: HTMLVisualDocumentStore
    let htmlVisualRenderer: HTMLVisualRenderer
    private var visualRetirement: Task<Void, Never>?
    let imagePreviews: HostImagePreviews
    let gateway: GatewayClient
    let directories: HostDirectories
    let preferenceExchange: SyncedPreferenceExchange
    #if os(iOS)
    let activities: ActiveTasksLiveActivityService
    #endif
    let automations: AutomationManagement
    let registration: DeviceRegistration

    init(host: GatewayHostConfiguration, routes: GatewayRoutes, speech: GatewaySpeechAccess, gateway: GatewayClient,
         htmlVisuals: HTMLVisualServices, syncedPreferences store: SyncedPreferenceStore, defaults: UserDefaults) {
        self.routes = routes
        self.speech = speech
        files = HostFileStore(host: host, routes: routes)
        imagePreviews = HostImagePreviews(access: files)
        self.gateway = gateway
        automations = AutomationManagement(host: host, gateway: gateway)
        directories = HostDirectories(gateway: gateway, hostID: host.id, hostLabel: host.errorLabel, defaults: defaults)
        preferenceExchange = SyncedPreferenceExchange(gateway: gateway, store: store, hostLabel: host.errorLabel)
        htmlVisualDocuments = HTMLVisualDocumentStore(hostID: host.id, access: files, cache: htmlVisuals.documents)
        htmlVisualRenderer = htmlVisuals.renderer
        #if os(iOS)
        activities = ActiveTasksLiveActivityService(hostID: host.id, hostName: host.displayName, legacyHostIDs: Set(host.legacyIDs))
        #endif
        registration = DeviceRegistration(
            appHostID: host.id, eventBaseURL: host.gatewayHTTPBaseURL()?.absoluteString, transport: gateway
        )
    }

    func beginFileRetirement() {
        if visualRetirement == nil {
            visualRetirement = Task { await htmlVisualDocuments.retire() }
        }
        files.beginRetirement()
    }

    func retireFiles() async {
        beginFileRetirement()
        await visualRetirement?.value
        await files.retire()
    }
}
