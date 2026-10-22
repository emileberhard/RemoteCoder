import Observation
import OSLog
import SwiftUI

@MainActor
final class RemoteCoderAppModel {
    let workspace: ChatWorkspaceModel
    let voiceCalls: VoiceCallCenter
    let energy: AppEnergyMonitor
    let theme = AppThemeStore()
    #if os(iOS)
    let incomingCalls: IncomingCallCoordinator
    let liveNavigationSetup = LiveNavigationSetupController()
    #endif
    var isApplicationActive: Bool { scenes.isActive }

    private let scenes: ScenePhaseAggregate
    private let logger = Logger(subsystem: "RemoteCoder", category: "ChatWorkspace")
    private var hasStarted = false
    private var bootstrapTask: Task<Void, Never>?
    private var hostSynchronizationTask: Task<Void, Never>?
    private var hostSynchronizationRequested = false
    private var diagnosticsHostTask: Task<Void, Never>?
    private let diagnostics = DiagnosticsLifecycle(exporter: DiagnosticsOutbox.shared)
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?

    init(workspace: ChatWorkspaceModel, voiceCalls: VoiceCallCenter, scenes: ScenePhaseAggregate) {
        self.workspace = workspace
        self.voiceCalls = voiceCalls
        self.scenes = scenes
        #if os(iOS)
        incomingCalls = IncomingCallCoordinator(workspace: workspace, voiceCalls: voiceCalls)
        #endif
        energy = AppEnergyMonitor(workspace: workspace)
        workspace.syncedPreferences.onExternalChange = { [weak self] in self?.applyPreferencesFromOtherDevices() }
    }

    private func applyPreferencesFromOtherDevices() {
        workspace.reloadSyncedPreferences()
        voiceCalls.call.reloadSelectedVoice()
        theme.reload()
    }

    static func live() -> RemoteCoderAppModel {
        let scope = AppStorageScope.current
        let defaults = scope.defaults
        #if RC_PERF_HARNESS
        let settings: HostStore
        if AppStorageScope.isOfflineReplay {
            settings = HostStore(hosts: [], activeHostID: nil, defaults: defaults,
                credentials: PerformanceReplayCredentials())
        } else {
            #if os(macOS)
            settings = PerfHarness.hostStore(defaults: defaults)
            #else
            settings = HostStore(defaults: defaults)
            #endif
        }
        #else
        let settings = HostStore(defaults: defaults)
        #endif
        let scenes = ScenePhaseAggregate()
        let voiceCalls = VoiceCallCenter()
        #if os(iOS)
        let deviceTools = DeviceToolHost(tools: [AgentPhotoCapture(isForeground: { scenes.isActive })])
        let makeBackgroundExecution: @MainActor () -> any BackgroundExecution = { UIKitBackgroundExecution() }
        let uploadContinuation: any UploadContinuation = ContinuedUploadProcessing()
        #else
        let deviceTools = DeviceToolHost(tools: [])
        let makeBackgroundExecution: @MainActor () -> any BackgroundExecution = { ForegroundOnlyBackgroundExecution() }
        let uploadContinuation: any UploadContinuation = ForegroundUploadContinuation()
        #endif
        let workspace = ChatWorkspaceModel(
            settings: settings,
            defaults: defaults,
            notificationApplicationIsActive: { scenes.isActive },
            voiceCalls: voiceCalls,
            makeBackgroundExecution: makeBackgroundExecution,
            uploadContinuation: uploadContinuation,
            deviceTools: deviceTools,
            gatewayPolicy: PerfBuild.isHarness ? .isolated : .production,
            storage: scope.hostStorage,
            dictationLibrary: PerfBuild.isHarness ? nil : SharedDictationLibrary(defaults: defaults,
                directory: scope.hostStorage.directory(for: .device).appending(path: "dictation-library"))
        )
        return RemoteCoderAppModel(workspace: workspace, voiceCalls: voiceCalls, scenes: scenes)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        HapticService.shared.bindCallState { [voiceCalls] in voiceCalls.call.isActive }
        #if RC_PERF_HARNESS
        PerfHarness.shared.start(workspace: workspace)
        #elseif os(iOS)
        incomingCalls.start()
        #endif
        Task { await AppPerformanceDiagnostics.shared.start() }
        #if os(iOS)
        LiveNavigationCoordinator.shared.configureGoogle(googleMapsAPIKey: workspace.settings.localConfiguration.googleMapsAPIKey ?? "")
        LiveNavigationCoordinator.shared.restoreIfNeeded()
        #endif
        energy.start()
        workspace.dictationLibrary?.requestPublication()

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            // Before bootstrap, which waits on the gateways: a slow or
            // unreachable host would otherwise leave the exporter draining into
            // segments it has no address for, and uploads are skipped silently.
            syncDiagnosticsHost(reason: "launch")
            logger.notice("chat bootstrap started")
            await workspace.bootstrap()
            logger.notice("chat bootstrap completed")
        }
        if workspace.notifications.isEnabled, workspace.gatewayPolicy.registersDevice {
            notificationAuthorizationTask = Task { [workspace] in
                _ = await workspace.notifications.authorization.ensureAuthorizedIfNeeded()
            }
        }
        registrationTask = Task { [workspace] in
            var registered = workspace.registrationCredentials
            for await credentials in Observations({ @MainActor in workspace.registrationCredentials }) {
                guard credentials != registered else { continue }
                registered = credentials
                await workspace.registerDeviceOnAllHosts()
            }
        }
        diagnosticsHostTask = Task { [weak self, workspace] in
            for await host in Observations({ @MainActor in workspace.settings.activeHost }) {
                guard let self, !Task.isCancelled else { return }
                diagnostics.setDestination(diagnosticsDestination(for: host?.configuration))
            }
        }
    }

    func apply(_ phase: ScenePhase, scene: UUID) async {
        guard let aggregate = scenes.update(phase, scene: scene) else { return }
        await enter(aggregate)
    }

    func detach(scene: UUID) async {
        guard let aggregate = scenes.remove(scene: scene) else { return }
        await enter(aggregate)
    }

    func synchronizeHosts() {
        hostSynchronizationRequested = true
        guard hostSynchronizationTask == nil else { return }
        hostSynchronizationTask = Task { [weak self] in
            while let self, hostSynchronizationRequested, !Task.isCancelled {
                hostSynchronizationRequested = false
                await workspace.synchronizeHosts()
            }
            self?.hostSynchronizationTask = nil
        }
    }

    func handleNotificationTap(payloadJSON: String) {
        workspace.events.receive(.completionNotificationTap(payloadJSON: payloadJSON))
    }

    func terminate() {
        workspace.dictationLibrary?.cancelPublication()
        bootstrapTask?.cancel()
        bootstrapTask = nil
        hostSynchronizationTask?.cancel()
        hostSynchronizationTask = nil
        diagnosticsHostTask?.cancel()
        diagnosticsHostTask = nil
        notificationAuthorizationTask?.cancel()
        notificationAuthorizationTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        diagnostics.update(destination: diagnosticsDestination(for: workspace.settings.activeHost?.configuration), phase: .stopped)
        workspace.teardown()
    }

    private func enter(_ phase: ScenePhase) async {
        logger.notice("scenePhase -> \(String(describing: phase), privacy: .public)")
        energy.refresh()
        switch phase {
        case .active:
            workspace.dictationLibrary?.requestPublication()
            syncDiagnosticsHost(reason: "foreground")
            synchronizeHosts()
            if workspace.gatewayPolicy.registersDevice {
                workspace.reconcileHosts()
                #if os(iOS)
                incomingCalls.refreshMicrophonePermission()
                #endif
            }
            await workspace.handleScenePhaseActive()
        case .inactive:
            await workspace.handleScenePhaseInactive()
        case .background:
            workspace.dictationLibrary?.cancelPublication()
            // Last chance to ship what this foreground session logged.
            diagnostics.update(destination: diagnosticsDestination(for: workspace.settings.activeHost?.configuration),
                               phase: .background)
            await workspace.handleScenePhaseBackground()
        @unknown default:
            break
        }
    }

    /// Diagnostics stay one device-wide exporter pointed at the visible host;
    /// changing its destination does not move any chat's ownership.
    private func syncDiagnosticsHost(reason: String) {
        diagnostics.update(destination: diagnosticsDestination(for: workspace.settings.activeHost?.configuration),
                           phase: .foreground(reason))
    }

    private func diagnosticsDestination(for host: GatewayHostConfiguration?) -> DiagnosticsDestination? {
        host.map { host in
            DiagnosticsDestination(host: host) { [weak workspace] request in
                guard let routes = await workspace?.routes(for: host) else { throw URLError(.cannotConnectToHost) }
                return try await routes.send(request, traffic: .exchange) { try await $1.data(for: $0) }
            }
        }
    }
}
