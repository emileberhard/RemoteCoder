import Foundation
import Observation
import OSLog
import SwiftUI

/// Owns one chat model per configured gateway host.
///
/// Selecting another host changes only which model is visible. Its predecessor
/// keeps its connection, draft, transcript, queued steering and running turns,
/// because each model's gateway and host id are fixed for its whole lifetime.
@MainActor
@Observable
final class ChatWorkspaceModel: LaunchRestoreHost {
    /// How many hosts bootstrap or refresh at once. A sleeping laptop must not
    /// delay the Mini's first rows, and an unbounded fan-out on a cold launch
    /// competes with the visible host's transcript load.
    private static let refreshConcurrency = BoundedFanOut.hostLimit

    let settings: HostStore
    let cluster: ClusterModel
    @ObservationIgnored let htmlVisuals: HTMLVisualServices
    @ObservationIgnored let siteIcons: SiteIconStore
    @ObservationIgnored let retainedTranscripts = TranscriptSurfaceRetention(capacity: 3)
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storage: HostStorage

    /// The one authoritative registry. It is observed, so replacing the selected
    /// host's model (an endpoint or token edit keeps the host id) invalidates the
    /// views bound to it instead of leaving them on the retired object.
    private let targets = ExecutionTargetRegistry()
    private var windows: [ChatWindowModel]

    private(set) var isQuiescing = false
    @ObservationIgnored private var terminationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var terminationTargets: [ChatTargetModel] = []
    @ObservationIgnored private var joiningTerminationTasks = false

    var pendingTerminationOperations: [String] {
        let workspace = joiningTerminationTasks ? ["Workspace: Navigation and host preparation"] : []
        return workspace + terminationTargets.compactMap { model in
            model.pendingTerminationOperation.map { model.hostDisplayName + ": " + $0 }
        }
    }
    /// Bootstrap work, keyed by the model object rather than its host id: a
    /// replacement takes the same host id, and its predecessor's late completion
    /// must not clear the replacement's handle.
    @ObservationIgnored private var prepareTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The foreground fan-out, so backgrounding cancels a pass that has not
    /// finished instead of letting it restart polling after the app is gone.
    @ObservationIgnored private var foregroundFanOutTask: Task<Void, Never>?
    @ObservationIgnored private var historyDrawerOpening: Task<Void, Never>?
    @ObservationIgnored private var showsHistoryDrawer = false
    @ObservationIgnored private var scenePhasePass = 0
    let notifications: CompletionNotificationCenter
    let pushTokens: PushTokenSources
    @ObservationIgnored private var hasBootstrapped = false
    private let condensedPaths = CondensedPathCache()
    private let sidebarDateLabels = ConversationSidebarDateCache()
    @ObservationIgnored private let makeModel: @MainActor (GatewayHostConfiguration, ModelPickerPreferences, SyncedPreferenceStore) -> ChatTargetModel
    @ObservationIgnored let voiceCalls: VoiceCallCenter
    @ObservationIgnored let gatewayPolicy: SharedGatewayPolicy
    @ObservationIgnored private let logger = AppLogger(category: "ChatWorkspace")

    func draftRetirementFailure(for target: ExecutionTarget?) -> (target: ExecutionTarget, message: String)? {
        targets.draftFailure(for: target)
    }

    func isRetryingDraftRetirement(_ target: ExecutionTarget) -> Bool { targets.isRetrying(target) }

    func retryDraftRetirement(_ target: ExecutionTarget) { targets.retry(target) }

    var notificationRoutingError: String?
    private(set) var agentNavigation: AgentNavigation?
    @ObservationIgnored private(set) var navigationGeneration = UUID()
    @ObservationIgnored private var notificationSceneGeneration = UUID()
    @ObservationIgnored private let notificationApplicationIsActive: @MainActor () -> Bool
    @ObservationIgnored private var notificationNavigationTask: Task<Void, Never>?
    @ObservationIgnored private var isCommittingNotificationNavigation = false
    @ObservationIgnored private var conversationSwitch: Task<Void, Never>?
    @ObservationIgnored private let loadConversationHeader: @MainActor (ChatTargetModel, String) async throws -> ConversationHeader
    let notificationSurfaces = NotificationSurfaceRegistry()
    let events = ExternalEventRouter(now: { .now })
    @ObservationIgnored private let launchRestore: LaunchRestore
    @ObservationIgnored private var accountMigration: Task<Void, Never>?
    @ObservationIgnored private var clusterRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var identityRetryTask: Task<Void, Never>?
    @ObservationIgnored private var isVerifyingIdentity = false
    @ObservationIgnored private var isDiscoveringRetiredState = true
    @ObservationIgnored private var migratingHosts: Set<UUID> = []
    @ObservationIgnored private var admittedHosts: Set<UUID> = []
    @ObservationIgnored private var pendingIdentityResumes: Set<UUID> = []
    private var identityResumeFailures: [UUID: String] = [:]
    private var accountMigrationIssues: [String] = []
    var accountMigrationIssue: String? {
        let issues = accountMigrationIssues + Array(identityResumeFailures.values)
        return issues.isEmpty ? nil : issues.joined(separator: "\n")
    }

    init(
        settings: HostStore,
        defaults: UserDefaults,
        makeModel: (@MainActor (GatewayHostConfiguration, ModelPickerPreferences, SyncedPreferenceStore) -> ChatTargetModel)? = nil,
        loadConversationHeader: @escaping @MainActor (ChatTargetModel, String) async throws -> ConversationHeader = {
            try await $0.conversationHeader(threadID: $1)
        },
        notificationApplicationIsActive: @escaping @MainActor () -> Bool = { false },
        notificationAuthorization: NotificationAuthorization = .live,
        voiceCalls: VoiceCallCenter,
        makeBackgroundExecution: @escaping @MainActor () -> any BackgroundExecution,
        uploadContinuation: any UploadContinuation,
        deviceTools: DeviceToolHost? = nil,
        gatewayPolicy: SharedGatewayPolicy,
        storage: HostStorage = .live,
        dictationLibrary: SharedDictationLibrary? = nil
    ) {
        self.settings = settings
        cluster = ClusterModel(defaults: defaults)
        self.storage = storage
        self.dictationLibrary = dictationLibrary
        #if DEBUG
        let htmlVisuals = HTMLVisualServices(directory: ProcessInfo.processInfo.arguments.contains("-html-visual-cold-cache")
            ? HTMLVisualServices.coldDirectory("html-visuals-cold")
            : storage.root.appending(path: "html-visuals"))
        #else
        let htmlVisuals = HTMLVisualServices(directory: storage.root.appending(path: "html-visuals"))
        #endif
        self.htmlVisuals = htmlVisuals
        siteIcons = SiteIconStore(directory: AppStorageScope.current.caches.appending(path: "RemoteCoder/SiteIcons", directoryHint: .isDirectory))
        self.defaults = defaults
        modelPickerPreferences = ModelPickerPreferences(defaults: defaults)
        drawerPreferences = ConversationDrawerPreferences(defaults: defaults)
        syncedPreferences = SyncedPreferenceStore(defaults: defaults, keys: gatewayPolicy.syncsPreferences ? Self.syncedPreferenceKeys : [])
        let launchHost = settings.activeHostID.flatMap { id in settings.hosts.first { $0.id == id } } ?? settings.hosts.first
        windows = [ChatWindowModel(
            id: UUID(), isPrimary: true,
            selectedTarget: launchHost.map { ExecutionTarget(hostID: $0.id) })]
        notifications = CompletionNotificationCenter(defaults: defaults, authorization: notificationAuthorization)
        pushTokens = PushTokenSources(defaults: defaults)
        self.voiceCalls = voiceCalls
        self.gatewayPolicy = gatewayPolicy
        self.makeModel = makeModel ?? {
            ChatTargetModel(host: $0, chatDefaults: defaults, modelPickerPreferences: $1, syncedPreferences: $2, voiceCalls: voiceCalls,
                            backgroundExecution: makeBackgroundExecution(), uploadContinuation: uploadContinuation,
                            gatewayPolicy: gatewayPolicy, storage: storage,
                            deviceTools: deviceTools, htmlVisuals: htmlVisuals, dictationLibrary: dictationLibrary)
        }
        self.loadConversationHeader = loadConversationHeader
        self.notificationApplicationIsActive = notificationApplicationIsActive
        launchRestore = LaunchRestore(defaults: defaults, loadHeader: loadConversationHeader)
        let accountDirectory = AccountDirectory(defaults: defaults, storage: storage, beginBackgroundExecution: { expiration in
            let execution = makeBackgroundExecution()
            execution.hold(named: "RemoteCoder.AccountReset") {
                expiration()
                execution.release()
            }
            return { execution.release() }
        }) { [targets] in targets.routes(for: $0) }
        self.accountDirectory = accountDirectory
        // Before the first model exists: the session index, pin store and
        // working-directory default are all read once at construction, so a
        // migration that ran later would be overwritten by its own consumers.
        HostScopedStateMigration.runIfNeeded(
            hosts: settings.hosts.map(\.configuration),
            activeHostID: settings.activeHostID ?? settings.hosts.first?.id,
            bundledWorkingDirectory: settings.localConfiguration.codexWorkdir,
            defaults: defaults,
            storage: storage
        )
        modelPickerPreferences.onChange = { [weak self] provider, previous in
            self?.applyModelPickerPreferences(for: provider, previousModelVisibility: previous)
        }
        syncedPreferences.onReplicaChange = { [weak self] in self?.syncPreferences() }
        startAccountMigration()
        reconcileHosts()
    }

    private func startAccountMigration() {
        isDiscoveringRetiredState = true
        let ledger = AccountRetirementMigration.Ledger(defaults: defaults)
        let admittedHosts = admittedHosts
        let storage = storage
        accountMigration = Task { [weak self] in
            guard let self else { return }
            let originalIDs = self.settings.hosts.map(\.id)
            let previous = await ledger.run(hosts: originalIDs, excluding: admittedHosts,
                storage: storage, discovered: { _ in }, finishedHost: { _ in })
            await self.resolveGatewayIdentities()
            guard !Task.isCancelled else { return }
            let hostIDs = self.settings.hosts.map(\.id)
            self.launchRestore.reloadPendingLocation()
            if Set(hostIDs) == Set(originalIDs) { self.finishAccountMigration(previous); return }
            let outcome = await ledger.run(hosts: hostIDs, excluding: admittedHosts, storage: storage, discovered: { [weak self] hosts in
                self?.isDiscoveringRetiredState = false
                self?.migratingHosts = hosts
                self?.reconcileHosts()
            }, finishedHost: { [weak self] host in
                self?.migratingHosts.remove(host)
                self?.reconcileHosts()
            })
            self.finishAccountMigration(.init(migrated: outcome.migrated, issues: previous.issues + outcome.issues))
        }
    }

    private func resolveGatewayIdentities() async {
        let migration = GatewayIdentityMigration(storage: storage)
        let candidates = settings.hosts.map(\.configuration).filter { !admittedHosts.contains($0.id) }
        pendingIdentityResumes.formUnion(await migration.unfinishedImports(hosts: candidates))
        let resolved = await GatewayIdentityLaunch.read(hosts: candidates, budget: .seconds(2)) { host in
            let routes = GatewayRoutes(host: host, directory: self.storage.directory(for: .host(host.id)),
                relayStorage: KeychainGatewayCredentials(scope: .relayRoute(hostID: host.id)),
                policy: self.gatewayPolicy, observeLocalNetwork: GatewayRoutes.observeLocalNetwork)
            do {
                let identity = try await routes.identity()
                await routes.retire()
                return identity
            } catch {
                await routes.retire()
                throw error
            }
        }
        for (host, identity) in resolved {
            do {
                let sources = try self.settings.identityMigrationSources(identity, for: host).sorted { $0.uuidString < $1.uuidString }
                for source in sources {
                    try await migration.migrate(from: source, to: identity.hostId)
                }
                try Task.checkCancellation()
                self.pendingIdentityResumes.insert(identity.hostId)
                try await self.settings.adoptIdentity(identity, for: host)
                for source in sources { try await migration.finish(from: source, to: identity.hostId) }
                self.pendingIdentityResumes.remove(identity.hostId)
            } catch is CancellationError {
            } catch {
                self.logger.notice("Gateway identity unresolved host=\(host.displayName): \(error.localizedDescription)")
            }
        }
    }

    private func retryGatewayIdentities() {
        guard !isQuiescing, hasBootstrapped, accountMigration == nil, identityRetryTask == nil else { return }
        let configured = Set(settings.hosts.map(\.id))
        pendingIdentityResumes.formIntersection(configured)
        identityResumeFailures = identityResumeFailures.filter { configured.contains($0.key) }
        let hosts = settings.hosts.filter { $0.configuration.gatewayID != $0.id || pendingIdentityResumes.contains($0.id) }.map(\.id)
        guard !hosts.isEmpty else { return }
        identityRetryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.identityRetryTask = nil }
            let migration = GatewayIdentityMigration(storage: self.storage)
            for hostID in hosts {
                guard !Task.isCancelled else { return }
                do {
                    if self.pendingIdentityResumes.contains(hostID) {
                        try await self.settings.resumeIdentityMigration(for: hostID, using: migration)
                        try Task.checkCancellation()
                        self.pendingIdentityResumes.remove(hostID)
                        self.identityResumeFailures[hostID] = nil
                        self.reconcileHosts()
                        self.launchRestore.reloadPendingLocation()
                        self.launchRestore.restore(using: self)
                        self.refreshCluster()
                    } else { try await self.verifyGatewayIdentity(hostID: hostID) }
                }
                catch is CancellationError { return }
                catch {
                    if self.pendingIdentityResumes.contains(hostID) {
                        self.identityResumeFailures[hostID] = "Saved gateway state could not finish importing: \(error.localizedDescription)"
                    }
                    self.logger.notice("Gateway identity unresolved host=\(hostID): \(error.localizedDescription)")
                }
            }
        }
    }

    func verifyGatewayIdentity(hostID: UUID) async throws {
        guard let host = settings.hosts.first(where: { $0.id == hostID })?.configuration else { return }
        guard host.gatewayID != host.id else { return }
        guard !isVerifyingIdentity else { throw GatewayIdentityMigration.MigrationFailure.verificationInProgress }
        guard let source = model(for: hostID) else { throw ConversationAgentNavigationError.hostUnavailable }
        isVerifyingIdentity = true
        defer { isVerifyingIdentity = false }
        let identity = try await source.hostServices.routes.identity()
        try Task.checkCancellation()
        try settings.verifyIdentity(identity, for: host)
        guard host.id != identity.hostId || host.gatewayID != identity.hostId else { return }
        guard !refusesSwitchWhileDictating, !voiceCalls.call.isActive else {
            throw VoiceCallUnavailable(message: "Finish dictation or Voice Mode before migrating this host.")
        }
        let ids = Set(settings.hosts.filter { $0.id == hostID || $0.configuration.gatewayID == identity.hostId }.map(\.id))
        let fenced = ids.union([identity.hostId])
        migratingHosts.formUnion(fenced)
        defer {
            migratingHosts.subtract(fenced)
            reconcileHosts()
            launchRestore.restore(using: self)
        }
        for model in models where ids.contains(model.hostID) { retire(model, reason: "verified gateway identity") }
        guard await targets.awaitRetirements() else { throw GatewayIdentityMigration.MigrationFailure.recovery }
        admittedHosts.subtract(ids)
        let ledger = AccountRetirementMigration.Ledger(defaults: defaults)
        _ = await ledger.run(hosts: Array(ids), excluding: admittedHosts, storage: storage, discovered: { _ in }, finishedHost: { _ in })
        let migration = GatewayIdentityMigration(storage: storage)
        let sources = try settings.identityMigrationSources(identity, for: host)
        for old in sources { try await migration.migrate(from: old, to: identity.hostId) }
        try Task.checkCancellation()
        pendingIdentityResumes.insert(identity.hostId)
        try await settings.adoptIdentity(identity, for: host)
        launchRestore.reloadPendingLocation()
        for old in sources { try await migration.finish(from: old, to: identity.hostId) }
        pendingIdentityResumes.remove(identity.hostId)
    }

    private func finishAccountMigration(_ outcome: AccountRetirementMigration.Outcome) {
        accountMigration = nil
        for issue in outcome.issues where !accountMigrationIssues.contains(issue) { accountMigrationIssues.append(issue) }
        if Task.isCancelled {
            isDiscoveringRetiredState = true
            if !isQuiescing { startAccountMigration() }
            return
        }
        isDiscoveringRetiredState = false
        reconcileHosts()
        if hasBootstrapped {
            launchRestore.restore(using: self)
            refreshCluster()
            retryGatewayIdentities()
        }
    }

    let automationDrafts = AutomationDraftStore()
    let transcriptionSettings = TranscriptionSettingsStore()
    let dictationLibrary: SharedDictationLibrary?
    let accountDirectory: AccountDirectory
    let modelPickerPreferences: ModelPickerPreferences
    let syncedPreferences: SyncedPreferenceStore
    let drawerPreferences: ConversationDrawerPreferences

    var codexAccount: AccountDirectory.AccountGroup? {
        accountDirectory.groups.first { $0.provider == .codex && $0.hosts.contains { $0.host.id == selectedHostID } }
    }

    func providerStatus(of provider: AgentProvider) -> ProviderStatus? {
        selectedHostID.flatMap(model(for:))?.providerHealth?.status(of: provider)
    }

    func select(target: ExecutionTarget) {
        guard !isQuiescing else { return }
        supersedePendingNavigation()
        guard model(for: target.hostID) != nil else { return }
        choose(target)
        applyVisibility()
        prepare(target: target)
    }

    private func choose(_ target: ExecutionTarget) {
        keyWindow.select(target)
        mirrorKeySelection()
    }

    private func mirrorKeySelection() {
        guard let target = keyWindow.selectedTarget else { return }
        if settings.activeHostID != target.hostID, let host = settings.hosts.first(where: { $0.id == target.hostID }) {
            settings.setActiveHost(host.configuration)
        }
    }

    private var persistedTarget: ExecutionTarget? {
        let host = settings.activeHostID.flatMap { id in settings.hosts.first { $0.id == id } } ?? settings.hosts.first
        return host.map { ExecutionTarget(hostID: $0.id) }
    }

    func synchronizeHosts() async {
        await settings.synchronize()
        await enrollInstallationCredentials()
    }

    func enrollInstallationCredentials() async {
        guard gatewayPolicy.registersDevice else { return }
        await settings.enrollInstallationCredentials(using: GatewayCredentialEnrollment()) { [voiceCalls] hostID in
            voiceCalls.call.callOwner?.hostID != hostID
        }
    }

    func incomingCallModel(routingID: UUID) -> ChatTargetModel? {
        let matching = models.filter { model in
            return settings.hosts.first(where: { $0.id == model.hostID })?.incomingCallHostID == routingID
        }
        return matching.count == 1 ? matching.first : nil
    }

    private func installScreen(of model: ChatTargetModel, in window: ChatWindowModel) {
        let preferred = window.isPrimary ? launchRestore.newChatDraft(on: model.target) ?? UUID() : window.id
        let isHeld = windows.contains { $0.screen(for: model.target)?.newChatDraftID == preferred }
        let screen = model.makeScreen(newChat: isHeld ? UUID() : preferred)
        installQuestionSubmissionGuard(on: screen)
        window.install(screen)
    }

    private func install(_ model: ChatTargetModel) {
        model.agentHosts = { [weak self] in self?.conversationAgentHosts ?? [] }
        model.agentCoverage = { [weak self] in self?.agentCoverage ?? [] }
        for window in windows { installScreen(of: model, in: window) }
        model.onConversationNavigation = { [weak self] in self?.supersedePendingNavigation() }
        model.onActiveSessionChange = { [weak self] _ in self?.openConversationDidChange() }
        model.onGatewayReconnect = { [weak self] in self?.retryGatewayIdentities() }
    }

    var clusterHosts: [ClusterModel.Host] {
        models.filter { $0.host.gatewayID == $0.hostID }.map { .init(configuration: $0.host, remote: $0.gatewayClient) }
    }

    var conversationAgentHosts: [ConversationAgentsHost] {
        models.map { .init(id: $0.hostID, name: $0.hostDisplayName, gateway: $0.gatewayClient, supportsCrossHost: $0.host.gatewayID == $0.hostID) }
    }

    var agentCoverage: [ClusterCoverage] {
        let byID = Dictionary(models.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        var coverage: [ClusterCoverage] = settings.hosts.map { host in
            guard let model = byID[host.id] else {
                return .init(hostId: host.id, name: host.displayName, state: .unknown)
            }
            let since = model.conversationList.lastSuccessfulRefreshAt
            if model.gatewayConnectivity.route == nil {
                return .init(hostId: host.id, name: host.displayName, state: .unreachable, since: model.gatewayUnreachableSince)
            }
            if model.conversationList.errorMessage != nil {
                return .init(hostId: host.id, name: host.displayName, state: .stale, staleThrough: since)
            }
            return .init(hostId: host.id, name: host.displayName, state: .ok)
        }
        var seen = Set(coverage.map(\.id))
        for member in cluster.membersByID.values where seen.insert(member.id).inserted {
            coverage.append(.init(hostId: member.id, name: member.name, state: .unknown))
        }
        return coverage
    }

    private func refreshCluster() {
        clusterRefreshTask?.cancel()
        clusterRefreshTask = Task { [weak self] in
            guard let self else { return }
            await cluster.refresh(hosts: clusterHosts)
        }
    }

    // MARK: - Selection

    /// Each window owns its selection. The key window's selection is mirrored
    /// into the active-host setting, so shortcuts and direct exec stay
    /// consistent — but it only decides which model is on screen, never where
    /// an existing model's RPCs go.
    var keyWindow: ChatWindowModel {
        windows.first { $0.id == events.keyScreenID } ?? windows.first { $0.isAttached } ?? windows[0]
    }

    func attachWindow(opening value: ConversationWindowValue?) -> ChatWindowModel {
        let window: ChatWindowModel
        switch value {
        case .newChat(let slot):
            window = windows.first { $0.id == slot } ?? addWindow(id: slot)
        case .conversation, .unsentDraft, nil:
            if let primary = windows.first(where: { $0.isPrimary && !$0.isAttached }) {
                window = primary
            } else {
                window = addWindow(id: UUID())
            }
        }
        window.attach()
        applyVisibility()
        logger.notice("window attached \(self.windowDiagnostics(window))")
        return window
    }

    private func addWindow(id: UUID) -> ChatWindowModel {
        let window = ChatWindowModel(id: id, isPrimary: false, selectedTarget: keyWindow.selectedTarget)
        for model in models { installScreen(of: model, in: window) }
        windows.append(window)
        return window
    }

    func detachWindow(_ window: ChatWindowModel) {
        window.detach()
        events.unregister(id: window.id)
        if !window.isPrimary {
            windows.removeAll { $0 === window }
            for screen in window.removeAllScreens() { screen.close() }
        }
        applyVisibility()
        logger.notice("window detached \(self.windowDiagnostics(window))")
    }

    func setWindowActive(_ window: ChatWindowModel, isActive: Bool) {
        if !isActive { window.cancelComposerFocus() }
        events.setActive(isActive, screen: window.id)
        mirrorKeySelection()
        applyVisibility()
        logger.notice("window active=\(isActive) \(self.windowDiagnostics(window))")
    }

    func windowDiagnostics(_ window: ChatWindowModel) -> String {
        let all = windows.map { "\($0.logID)\($0.isPrimary ? "*" : "")\($0.isAttached ? "" : "(detached)")=\($0.selectedTarget?.id ?? "none")" }
        return "window=\(window.logID) key=\(keyWindow.logID) windows=[\(all.joined(separator: ", "))]"
    }

    func setWindowVisible(_ window: ChatWindowModel, isVisible: Bool) {
        window.setVisible(isVisible)
        publishPresentation()
    }

    func setWindowOpen(_ window: ChatWindowModel) {
        events.setOpen(screen: window.id)
        mirrorKeySelection()
        applyVisibility()
    }

    func setWindowKey(_ window: ChatWindowModel) {
        if keyWindow !== window { keyWindow.cancelComposerFocus() }
        events.setKey(screen: window.id)
        mirrorKeySelection()
        applyVisibility()
        logger.notice("window key \(self.windowDiagnostics(window))")
    }

    var selectedHostID: UUID? { selectedHost?.id }

    var selectedHost: GatewayHostConfiguration? {
        keyWindow.selectedTarget.flatMap { target in settings.hosts.first { $0.id == target.hostID }?.configuration }
    }

    var selectedModel: ChatTargetModel? {
        keyWindow.selectedTarget.flatMap { model(for: $0.hostID) }
    }

    var selectedScreen: ChatScreenModel? { keyWindow.selectedScreen }

    var allScreens: [ChatScreenModel] {
        windows.flatMap { window in models.compactMap { window.screen(for: $0.target) } }
    }

    func screen(for hostID: UUID) -> ChatScreenModel? {
        model(for: hostID).flatMap { keyWindow.screen(for: $0.target) }
    }

    private func isShown(_ screen: ChatScreenModel) -> Bool {
        windows.contains { $0.selectedScreen === screen }
    }

    var hasMultipleHosts: Bool { settings.hosts.count > 1 }

    var hasOpenWindow: Bool { windows.contains { $0.isAttached } }

    private func applyModelPickerPreferences(for provider: AgentProvider, previousModelVisibility: ModelVisibility) {
        for model in models { model.applyModelPickerPreferences(for: provider, previousModelVisibility: previousModelVisibility) }
    }

    func refreshNewChatDefaults() {
        for screen in allScreens where !screen.showsUnsentContent { screen.refreshNewChatDefaults() }
    }

    func setAutoSpeakEnabled(_ enabled: Bool) {
        SpeechPreferences.shared.isAutoSpeakEnabled = enabled
        if !enabled {
            for model in models { model.speech.cancel() }
        }
    }

    var models: [ChatTargetModel] { targets.models }

    func model(for hostID: UUID) -> ChatTargetModel? {
        targets.model(for: settings.canonicalHostID(hostID))
    }

    func routes(for host: GatewayHostConfiguration) -> GatewayRoutes? {
        targets.routes(for: host)
    }

    /// Audio is one device-wide resource: the voice surface belongs to the host
    /// whose thread the live call is bound to, not to whichever host the sidebar
    /// selected afterwards.
    var voiceCallOwner: ChatScreenModel? {
        guard let owner = voiceCalls.call.callOwner else { return nil }
        return screen(for: owner.hostID)
    }

    func select(hostID: UUID) {
        guard !isQuiescing else { return }
        supersedePendingNavigation()
        guard settings.hosts.contains(where: { $0.id == hostID }) else { return }
        let target = ExecutionTarget(hostID: hostID)
        guard keyWindow.selectedTarget != target else { return }
        choose(target)
        applyVisibility()
        // A host visited for the first time has not bootstrapped yet.
        prepare(target: target)
    }

    /// The selection can also change from Settings; adopt it without touching
    /// any model's connection.
    func syncSelection() {
        guard !isQuiescing else { return }
        guard keyWindow.selectedTarget != persistedTarget else { return }
        supersedePendingNavigation()
        keyWindow.select(persistedTarget)
        applyVisibility()
        if let target = keyWindow.selectedTarget { prepare(target: target) }
    }

    private func applyVisibility() {
        publishPresentation()
        openConversationDidChange()
    }

    private func publishPresentation() {
        let key = keyWindow
        let anyAttached = windows.contains { $0.isAttached }
        for window in windows {
            window.setPresentation(presenting: window.isAttached || !anyAttached, isKey: window === key)
        }
        let shows = windows.contains(where: \.showsHistoryDrawer)
        guard shows != showsHistoryDrawer else { return }
        showsHistoryDrawer = shows
        historyDrawerOpening?.cancel()
        historyDrawerOpening = shows ? Task { [weak self] in
            guard let self else { return }
            await self.withHostConcurrency(self.models) { await $0.historyDrawerOpened() }
        } : nil
    }

    // MARK: - Host reconciliation

    /// Adds models for new hosts, retires removed ones, and replaces a model
    /// whose endpoint or credential changed. A rename only relabels.
    func reconcileHosts() {
        guard !isQuiescing else { return }
        let hosts = settings.hosts
        let configuredIDs = Set(hosts.map(\.id))
        accountDirectory.reconcile(hosts.map(\.configuration))
        for model in models {
            guard let current = hosts.first(where: { $0.id == model.hostID }), model.host.hasSameConnection(as: current.configuration) else {
                retire(model, reason: "host removed or reconfigured")
                continue
            }
        }

        var reconciled: [ChatTargetModel] = []
        var installedHostIDs: Set<UUID> = []
        for host in hosts {
            if let existing = model(for: host.id) {
                if existing.host.hasSameConnection(as: host.configuration) {
                    existing.applyHostRename(host.name)
                    reconciled.append(existing)
                    continue
                }
                retire(existing, reason: "reconfigured")
            }
            if isDiscoveringRetiredState || migratingHosts.contains(host.id) || pendingIdentityResumes.contains(host.id) { continue }
            // Flush the predecessor before loading the same host-scoped files.
            if targets.hasRunningRetirement(hostID: host.id) || targets.isRetiring(ExecutionTarget(hostID: host.id)) { continue }
            admittedHosts.insert(host.id)
            let model = makeModel(host.configuration, modelPickerPreferences, syncedPreferences)
            install(model)
            reconciled.append(model)
            installedHostIDs.insert(host.id)
        }

        targets.replaceAll(with: reconciled)
        accountDirectory.routesBecameAvailable(for: installedHostIDs)
        for window in windows where window.selectedTarget.map({ configuredIDs.contains($0.hostID) }) != true {
            window.select(persistedTarget)
        }
        if hasBootstrapped {
            for model in models { prepare(target: model.target) }
        }
        applyVisibility()
    }

    /// Retirement is fenced synchronously *before* the model leaves the registry:
    /// after `beginRetirement()` returns, no suspended work inside it can resume
    /// into a restart, a send or a device-wide publication.
    private func retire(_ model: ChatTargetModel, reason: String) {
        logger.notice(
            "retiring chat model host=\(model.hostDisplayName) reason=\(reason)"
        )
        model.hostServices.beginFileRetirement()
        model.beginRetirement()
        for window in windows { window.removeScreen(for: model.target) }
        let preparing = prepareTasks.removeValue(forKey: ObjectIdentifier(model))
        preparing?.cancel()
        targets.retire(model, cleanup: {
            await model.hostServices.retireFiles()
            await preparing?.value
            return await model.retire()
        }, completion: { [weak self] in
            self?.reconcileHosts()
        })
    }

    private func installQuestionSubmissionGuard(on screen: ChatScreenModel) {
        screen.idleQuestionSubmissionBlock = { [weak self, weak screen] in
            guard let self, let screen else { return "This conversation is no longer available." }
            return self.idleQuestionSubmissionBlock(for: screen)
        }
    }

    private func idleQuestionSubmissionBlock(for screen: ChatScreenModel) -> String? {
        guard isShown(screen) else { return "Reopen this conversation before answering its question." }
        return nil
    }

    func prepareVoiceCall(
        from selected: ChatScreenModel,
        startsFreshChat: Bool,
        configuration: RemoteCoderVoiceConfiguration?
    ) async throws -> ChatScreenModel? {
        var voiceScreen = voiceCallOwner ?? selected
        if !voiceScreen.target.realtimeVoice.isActive {
            if startsFreshChat {
                guard let destination = newConversationDestination(preferredHostID: voiceScreen.hostID) else {
                    throw VoiceCallUnavailable(message: "Add a gateway host before starting Voice Mode.")
                }
                voiceScreen = destination
            }
        }
        // Bring the chat under the call with it, so the transcript on screen is
        // the conversation the user is talking to.
        if voiceScreen !== selectedScreen {
            select(target: voiceScreen.executionTarget)
        }
        // A call already in flight is rejoined, never restarted: clearing the
        // chat under it would strand the thread the call is bound to.
        guard !voiceScreen.target.realtimeVoice.isActive else { return voiceScreen }
        let navigation = navigationGeneration
        let presentation = voiceScreen.transcriptIdentity
        await voiceScreen.target.restoreCachedCodexModels()
        guard !Task.isCancelled, !voiceScreen.isRetired, selectedScreen === voiceScreen,
              navigationGeneration == navigation, voiceScreen.transcriptIdentity == presentation else { return nil }
        try voiceScreen.prepareForVoiceModePresentation(startsFreshChat: startsFreshChat, configuration: configuration)
        let conversationID = voiceScreen.currentConversationID
        VoiceModeDiagnostics.log("voice home resolution started")
        await voiceScreen.prepareVoiceModeWorkingDirectory(startsFreshChat: startsFreshChat)
        guard voiceScreen.currentConversationID == conversationID else { return nil }
        VoiceModeDiagnostics.log("voice home resolution completed")
        return voiceScreen
    }

    func startFreshVoiceCall(configuration: RemoteCoderVoiceConfiguration?) async throws -> UUID? {
        await finishHostChanges()
        await accountDirectory.restore()
        guard let selected = selectedScreen else {
            throw VoiceCallUnavailable(message: "Add a gateway host before starting Voice Mode.")
        }
        guard let voiceScreen = try await prepareVoiceCall(from: selected, startsFreshChat: true, configuration: configuration) else {
            return nil
        }
        try await voiceCalls.call.startWithLiveActivity(using: voiceScreen.target, hostName: voiceScreen.target.hostDisplayName)
        if case .failed(let message) = voiceCalls.call.state {
            throw VoiceCallUnavailable(message: message)
        }
        return voiceCalls.call.liveCallID
    }

    func selectLiveVoiceCall(_ callID: UUID) -> Bool {
        guard voiceCalls.call.liveCallID == callID, let owner = voiceCallOwner else { return false }
        if owner !== selectedScreen { select(target: owner.executionTarget) }
        return true
    }

    @discardableResult
    func finishHostChanges() async -> Bool {
        await accountMigration?.value
        return await targets.awaitRetirements()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !isQuiescing else { return }
        await targets.awaitRetirements()
        guard !isQuiescing, !Task.isCancelled else { return }
        await accountDirectory.restore()
        guard !isQuiescing, !Task.isCancelled else { return }
        hasBootstrapped = true
        accountDirectory.startForeground()
        if accountMigration == nil { launchRestore.restore(using: self) }
        await withHostConcurrency(models) { model in
            await self.prepareAndRegister(model)
        }
        events.setNavigationReady()
        refreshCluster()
        retryGatewayIdentities()
    }

    private func prepare(target: ExecutionTarget) {
        guard !isQuiescing else { return }
        guard hasBootstrapped, let model = model(for: target.hostID),
              !model.isRetired, !model.isPrepared else { return }
        let key = ObjectIdentifier(model)
        guard prepareTasks[key] == nil else { return }
        prepareTasks[key] = Task { @MainActor [weak self] in
            await self?.prepareAndRegister(model)
            self?.prepareTasks.removeValue(forKey: key)
        }
    }

    func prepareAndRegister(_ model: ChatTargetModel) async {
        guard !isQuiescing else { return }
        await model.prepareIfNeeded()
        guard model.acceptsWork, !isQuiescing else { return }
        await registerDevice(on: model)
    }

    func handleEnergyPolicyChanged(_ policy: AppEnergyPolicy) {
        for model in models { model.handleEnergyPolicyChanged(policy) }
    }

    func releaseReusableCaches() {
        retainedTranscripts.removeAll()
        for model in models { model.releaseReusableCaches() }
        htmlVisuals.renderer.releaseReusableCaches()
    }

    func handleScenePhaseActive() async {
        guard !isQuiescing else { return }
        let pass = beginScenePhasePass()
        accountDirectory.startForeground()
        for model in connectedHostModels { model.directories.syncFavorites() }
        syncPreferences()
        retryGatewayIdentities()
        foregroundFanOutTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.withHostConcurrency(self.models) { model in
                guard self.scenePhasePass == pass else { return }
                await model.handleScenePhaseActive()
            }
            guard Task.isCancelled == false else { return }
            self.applyVisibility()
        }
        foregroundFanOutTask = task
        await task.value
        if foregroundFanOutTask == task { foregroundFanOutTask = nil }
    }

    func handleScenePhaseInactive() async {
        guard !isQuiescing else { return }
        let pass = beginScenePhasePass()
        notificationSceneGeneration = UUID()
        notifications.dismiss()
        for model in models {
            guard scenePhasePass == pass else { return }
            await model.handleScenePhaseInactive()
        }
    }

    func handleScenePhaseBackground() async {
        guard !isQuiescing else { return }
        let pass = beginScenePhasePass()
        notificationSceneGeneration = UUID()
        notifications.dismiss()
        accountDirectory.stopForeground()
        identityRetryTask?.cancel()
        siteIcons.stopFetching()
        // The app is leaving: a foreground pass still in flight would otherwise
        // resume and restart the very polling this is tearing down.
        foregroundFanOutTask?.cancel()
        foregroundFanOutTask = nil
        for model in models {
            guard scenePhasePass == pass else { return }
            await model.handleScenePhaseBackground()
        }
    }

    private func beginScenePhasePass() -> Int {
        scenePhasePass += 1
        return scenePhasePass
    }

    func setHistoryDrawerOpen(_ isOpen: Bool, overlaysTranscript: Bool, in window: ChatWindowModel) {
        window.setHistoryDrawerOpen(isOpen, overlaysTranscript: overlaysTranscript)
        publishPresentation()
    }

    func teardown() {
        supersedePendingNavigation()
        for window in windows { window.cancelComposerFocus() }
        notifications.dismiss()
        accountDirectory.stop()
        siteIcons.stopFetching()
        for task in prepareTasks.values { task.cancel() }
        prepareTasks.removeAll()
        foregroundFanOutTask?.cancel()
        foregroundFanOutTask = nil
        historyDrawerOpening?.cancel()
        historyDrawerOpening = nil
        clusterRefreshTask?.cancel()
        clusterRefreshTask = nil
        identityRetryTask?.cancel()
        notifications.stop()
        for model in models {
            model.hostServices.beginFileRetirement()
            model.beginRetirement()
        }
    }

    func beginTermination() {
        guard !isQuiescing else { return }
        isQuiescing = true
        scenePhasePass += 1
        navigationGeneration = UUID()
        terminationTasks = Array(prepareTasks.values) + [foregroundFanOutTask, notificationNavigationTask, conversationSwitch, accountMigration, clusterRefreshTask, identityRetryTask].compactMap { $0 }
        for task in terminationTasks { task.cancel() }
        accountDirectory.stop()
        terminationTargets = models + targets.retiringModels
        for model in terminationTargets {
            model.beginTermination(draftSave: targets.draftSaveForTermination(of: model.target))
        }
    }

    func flushForTermination() async -> [String] {
        beginTermination()
        joiningTerminationTasks = true
        for task in terminationTasks { await task.value }
        joiningTerminationTasks = false
        terminationTasks.removeAll()
        var failures: [String] = []
        for model in terminationTargets { failures += await model.flushForTermination() }
        await dictationLibrary?.finishPendingCaptures()
        do { try await htmlVisuals.renderer.flush() }
        catch { failures.append("HTML visuals: " + error.localizedDescription) }
        return failures
    }

    func resumeAfterTermination() {
        guard isQuiescing else { return }
        for model in terminationTargets { model.resumeAfterTermination() }
        terminationTargets.removeAll()
        isQuiescing = false
        if accountMigration == nil, isDiscoveringRetiredState { startAccountMigration() }
        reconcileHosts()
        applyVisibility()
        for model in models { prepare(target: model.target) }
        Task { [weak self] in await self?.handleScenePhaseActive() }
    }

    /// Pull-to-refresh covers every configured host; each publishes its own
    /// result as soon as it lands and keeps cached rows when it fails.
    func refreshAllHosts() async {
        guard !isQuiescing else { return }
        await withHostConcurrency(models) { model in
            await model.conversationList.manualRefresh(reason: "pull-to-refresh-all-hosts")
        }
    }

    var registrationCredentials: DeviceCredentials? {
        pushTokens.credentials(alertsEnabled: notifications.isEnabled)
    }

    func registerDeviceOnAllHosts() async {
        guard !isQuiescing else { return }
        await finishHostChanges()
        await withHostConcurrency(models) { model in
            await self.registerDevice(on: model)
        }
    }

    private func registerDevice(on model: ChatTargetModel) async {
        guard gatewayPolicy.registersDevice,               let credentials = registrationCredentials else { return }
        let registration = model.hostServices.registration
        registration.update(credentials: credentials)
        await registration.settle()
        guard !model.isRetired, case .registered(let routingID) = registration.state,
              let host = settings.hosts.first(where: { $0.id == model.hostID }) else { return }
        do {
            try settings.enrollIncomingCalls(host: host.configuration, serverHostID: routingID)
        } catch {
            registration.reject(error)
        }
    }

    /// Runs `body` for every host, at most `refreshConcurrency` at a time, with
    /// the visible host first: its rows are the ones the user is waiting for.
    private func withHostConcurrency(
        _ models: [ChatTargetModel],
        _ body: @escaping @MainActor (ChatTargetModel) async -> Void
    ) async {
        await BoundedFanOut.run(prioritized(models), limit: Self.refreshConcurrency, deadline: nil, skipping: { $0.isRetired }, body)
    }

    /// The selected host goes first; the rest keep their configured order.
    private func prioritized(_ models: [ChatTargetModel]) -> [ChatTargetModel] {
        guard let selectedModel, let index = models.firstIndex(where: { $0 === selectedModel }) else {
            return models
        }
        var ordered = models
        let selected = ordered.remove(at: index)
        ordered.insert(selected, at: 0)
        return ordered
    }

    // MARK: - Sidebar projection

    func sidebarInputs(in window: ChatWindowModel) -> [ConversationSidebarHostInput] {
        models.map { sidebarInput(for: $0, in: window) }
    }

    private func sidebarInput(for model: ChatTargetModel, in window: ChatWindowModel) -> ConversationSidebarHostInput {
        let activity = model.historyActivityStates
        return ConversationSidebarHostInput(
            hostID: model.hostID,
            hostName: targetName(of: model),
            threads: model.conversationList.threads,
            marks: model.conversationList.marks,
            remoteHomePath: model.remoteHomePath,
            activityByThreadID: activity,
            activeThreadID: window.screen(for: model.target)?.openThreadID,
            loadingThreadID: window.screen(for: model.target)?.loadingTranscriptID,
            isLoading: model.conversationList.isLoading || model.conversationList.isLoadingOlder,
            errorMessage: model.conversationList.errorMessage,
            isGatewayRestarting: model.gatewayConnectivity == .restarting,
            questionAskTimesByThreadID: model.questionAskTimesByThreadID,
            waitingSinceByThreadID: model.waitingSinceByThreadID(in: activity),
            projects: model.conversationList.projects,
            settlementEdits: model.conversationList.settlementEdits,
            canLoadMore: model.conversationList.canLoadOlder(query: window.drawerQuery),
            hasDiscardedHeaders: model.conversationList.hasDiscardedHeaders,
            unloadedPins: model.conversationList.unloadedPinnedThreads
        )
    }

    func attentionInputs() -> [ConversationSidebarHostInput] {
        models.map { model in
            let activity = model.historyActivityStates
            return ConversationSidebarHostInput(
                hostID: model.hostID, hostName: targetName(of: model),
                threads: model.conversationList.threads, marks: model.conversationList.marks,
                remoteHomePath: nil, activityByThreadID: activity,
                activeThreadID: nil, loadingThreadID: nil, isLoading: false, errorMessage: nil,
                questionAskTimesByThreadID: model.questionAskTimesByThreadID,
                waitingSinceByThreadID: model.waitingSinceByThreadID(in: activity)
            )
        }
    }

    func targetName(of model: ChatTargetModel) -> String { model.hostDisplayName }

    func conversationTargetName(of screen: ChatScreenModel) -> String {
        targetName(of: screen.target)
    }

    func sidebarSnapshot(arrangedBy layout: ConversationDrawerLayout, in window: ChatWindowModel) -> ConversationSidebarSnapshot {
        let now = Date.now
        let inputs = sidebarInputs(in: window)
        let admitted = ConversationSidebarProjection.admittingLayout(hosts: inputs, layout: layout)
        let drafts = unsentDraftRows(in: window, now: now)
        let shownDraftCount = window.revealsAllDrafts || !window.drawerQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? drafts.count : min(drafts.count, UnsentDraftRow.collapsedLimit)
        return ConversationSidebarSnapshot(
            drafts: Array(drafts.prefix(shownDraftCount)), hiddenDraftCount: drafts.count - shownDraftCount,
            items: sidebarItems(inputs, in: window, layout: admitted, arrangement: drawerArrangement(in: window), now: now),
            hostStates: ConversationSidebarProjection.hostStates(hosts: inputs), admittedLayout: admitted
        )
    }

    func unfoldedSidebarRows(arrangedBy layout: ConversationDrawerLayout, in window: ChatWindowModel) -> [ConversationSidebarRow] {
        let inputs = sidebarInputs(in: window)
        let admitted = ConversationSidebarProjection.admittingLayout(hosts: inputs, layout: layout)
        return ConversationSidebarNavigation.rows(
            of: sidebarItems(inputs, in: window, layout: admitted, arrangement: unfoldedArrangement(in: window), now: .now)
        )
    }

    private func unsentDraftRows(in window: ChatWindowModel, now: Date) -> [UnsentDraftRow] {
        let shown = window.selectedScreen.flatMap { screen in
            screen.shownNewChatDraft.map { UnsentDraftAddress(target: screen.executionTarget, draftID: $0) }
        }
        let inputs = models.map { model in
            UnsentDraftRow.TargetInput(target: model.target, hostName: targetName(of: model),
                                       remoteHomePath: model.remoteHomePath, drafts: model.drafts.listedUnsentDrafts)
        }
        return UnsentDraftRow.rows(from: inputs, selected: shown,
                                   showsHostLabels: ConversationSidebarProjection.showsHostLabels(targetCount: models.count),
                                   query: window.drawerQuery, condensedPaths: condensedPaths, now: now)
    }

    func isShowingUnsentDraft(_ address: UnsentDraftAddress, in window: ChatWindowModel) -> Bool {
        window.selectedTarget == address.target && window.selectedScreen?.shownNewChatDraft == address.draftID
    }

    func openUnsentDraft(_ address: UnsentDraftAddress, in window: ChatWindowModel) -> ConversationSwitchOutcome {
        guard let model = model(for: address.target.hostID),
              !model.drafts.isDiscarding(address.draftID),
              let screen = window.screen(for: address.target) else { return .unchanged }
        if isShowingUnsentDraft(address, in: window) { return .unchanged }
        if refusesSwitchWhileDictating || holdsDictatedDraft(address, besides: screen) { return .refusedWhileDictating }
        supersedePendingNavigation()
        conversationSwitch = Task { [weak self, weak screen] in
            guard let self, let screen, !Task.isCancelled else { return }
            conversationSwitch = nil
            guard !refusesSwitchWhileDictating, !holdsDictatedDraft(address, besides: screen) else { return }
            for holder in screens(holding: address) where holder !== screen { holder.releaseNewChatDraft() }
            screen.openUnsentDraft(address.draftID)
            select(target: address.target)
        }
        return .changed
    }

    enum UnsentDraftDiscard: Equatable {
        case discarded(wasShown: Bool)
        case refusedWhileDictating
    }

    func discardUnsentDraft(_ address: UnsentDraftAddress, undoWindow: Duration) -> UnsentDraftDiscard {
        guard let model = model(for: address.target.hostID) else {
            return .discarded(wasShown: false)
        }
        if model.voice.isRecording || model.voice.isTranscribing { return .refusedWhileDictating }
        model.drafts.discardUnsentDraft(address.draftID, after: undoWindow) { [weak model] draft in
            model?.fileImports.release(draft)
        }
        let holders = screens(holding: address)
        let wasShown = windows.contains { isShowingUnsentDraft(address, in: $0) }
        if !holders.isEmpty {
            Task { for screen in holders where screen.newChatDraftID == address.draftID { screen.releaseNewChatDraft() } }
        }
        return .discarded(wasShown: wasShown)
    }

    private func screens(holding address: UnsentDraftAddress) -> [ChatScreenModel] {
        windows.compactMap { $0.screen(for: address.target) }.filter { $0.newChatDraftID == address.draftID }
    }

    private func holdsDictatedDraft(_ address: UnsentDraftAddress, besides screen: ChatScreenModel) -> Bool {
        guard screens(holding: address).contains(where: { $0 !== screen }) else { return false }
        return screen.target.voice.isRecording || screen.target.voice.isTranscribing
    }

    func restoreUnsentDraft(_ address: UnsentDraftAddress) {
        model(for: address.target.hostID)?.drafts.restoreUnsentDraft(address.draftID)
    }

    func quickEntryRecents(in window: ChatWindowModel, limit: Int) -> [ConversationSidebarRow] {
        var arrangement = ConversationDrawerArrangement()
        arrangement.isSettledFolded = false
        arrangement.settledRowLimit = nil
        return QuickEntryRecents.rows(from: sidebarItems(sidebarInputs(in: window), in: window, layout: .live(at: .now),
                                                         arrangement: arrangement, now: .now), limit: limit)
    }

    private func sidebarItems(_ inputs: [ConversationSidebarHostInput], in window: ChatWindowModel,
                              layout: ConversationDrawerLayout,
                              arrangement: ConversationDrawerArrangement, now: Date) -> [ConversationSidebarItem] {
        ConversationSidebarProjection.items(hosts: inputs, selectedHostID: window.selectedTarget?.hostID,
            layout: layout, arrangement: arrangement,
            condensedPaths: condensedPaths, now: now, dateLabels: sidebarDateLabels)
    }

    func captureDrawerOpening(at date: Date, in window: ChatWindowModel) -> ConversationDrawerLayout {
        ConversationSidebarProjection.layout(hosts: sidebarInputs(in: window), at: date)
    }

    func loadOlderHistory(on target: ExecutionTarget, in window: ChatWindowModel) async {
        guard let owner = model(for: target.hostID), !owner.isRetired else { return }
        let query = window.drawerQuery
        let showsHostLabel = ConversationSidebarProjection.showsHostLabels(targetCount: models.count)
        await owner.conversationList.loadOlder(query: query) { header in
            ConversationSidebarProjection.matches(title: owner.conversationList.pinnedName(for: header.id) ?? header.displayTitle,
                workingDirectory: condensedPaths.condensedPath(header.cwd, remoteHomePath: owner.remoteHomePath),
                hostName: showsHostLabel ? targetName(of: owner) : nil, query: query)
        }
    }

    func loadOlderHistory(in window: ChatWindowModel) async {
        await withHostConcurrency(models) { model in
            await self.loadOlderHistory(on: model.target, in: window)
        }
    }

    private func drawerArrangement(in window: ChatWindowModel) -> ConversationDrawerArrangement {
        ConversationDrawerArrangement(
            mode: drawerPreferences.mode,
            unreadOnly: drawerPreferences.unreadOnly,
            isPinnedFolded: drawerPreferences.isPinnedFolded,
            isAutomationsFolded: drawerPreferences.isAutomationsFolded,
            isSettledFolded: drawerPreferences.isSettledFolded,
            foldedProjects: drawerPreferences.foldedProjects,
            revealedProjects: window.revealedProjects,
            projectRowLimit: SidebarPresentation.projectRowLimit,
            automationRowLimit: window.revealsAllAutomations ? nil : ConversationDrawerArrangement.initialAutomationRowLimit,
            settledRowLimit: window.settledRowLimit,
            query: window.drawerQuery
        )
    }

    private func unfoldedArrangement(in window: ChatWindowModel) -> ConversationDrawerArrangement {
        var arrangement = drawerArrangement(in: window)
        arrangement.isPinnedFolded = false
        arrangement.isAutomationsFolded = false
        arrangement.isSettledFolded = false
        arrangement.foldedProjects = []
        arrangement.projectRowLimit = nil
        arrangement.automationRowLimit = nil
        arrangement.settledRowLimit = nil
        return arrangement
    }

    // MARK: - Drawer marks and settlement

    func markRead(_ addresses: [ConversationAddress]) {
        for (target, threadIDs) in grouped(addresses) {
            model(for: target.hostID)?.conversationList.markRead(threadIDs: threadIDs)
        }
    }

    func markUnread(_ address: ConversationAddress) {
        model(for: address.hostID)?.conversationList.markUnread(threadID: address.threadID)
    }

    func markAllRead() {
        for model in models { model.conversationList.markAllRead() }
    }

    func settle(_ addresses: [ConversationAddress]) -> [ExecutionTarget: [ConversationSettlementEdit]] {
        var settled: [ExecutionTarget: [ConversationSettlementEdit]] = [:]
        for (target, threadIDs) in grouped(addresses) {
            guard let owner = model(for: target.hostID) else { continue }
            let undos = owner.conversationList.settle(threadIDs: threadIDs.filter { !isRunning($0, on: owner) },
                                                      newestRequestAt: owner.newestRequestTimesByThreadID)
            if !undos.isEmpty { settled[target] = undos }
        }
        return settled
    }

    func unsettle(_ addresses: [ConversationAddress]) {
        for (target, threadIDs) in grouped(addresses) {
            model(for: target.hostID)?.conversationList.unsettle(threadIDs: threadIDs)
        }
    }

    func undoSettle(_ settled: [ExecutionTarget: [ConversationSettlementEdit]]) {
        for (target, undos) in settled {
            model(for: target.hostID)?.conversationList.undoSettle(undos)
        }
    }

    func settlement(of address: ConversationAddress, capturedIn layout: ConversationDrawerLayout?) -> ConversationSidebarRow.Settlement {
        guard let owner = model(for: address.hostID),
              let thread = owner.conversationList.header(id: address.threadID) else { return .unavailable }
        return ConversationSidebarProjection.settlement(
            of: thread, marks: owner.conversationList.marks, activity: owner.historyActivityState(of: thread.id),
            questionAskTimes: owner.questionAskTimes(of: thread.id),
            waitingSince: owner.waitingSince(of: thread.id),
            settlementEdit: owner.conversationList.settlementEdits[thread.id] ?? 0,
            captured: layout?.ranks(on: address.target)[thread.id],
            at: layout?.capturedAt ?? Int64(Date.now.timeIntervalSince1970))
    }

    func isRunning(_ address: ConversationAddress) -> Bool {
        model(for: address.hostID).map { isRunning(address.threadID, on: $0) } ?? false
    }

    private func isRunning(_ threadID: String, on owner: ChatTargetModel) -> Bool {
        owner.historyActivityState(of: threadID) == .working
    }

    private func grouped(_ addresses: [ConversationAddress]) -> [ExecutionTarget: [String]] {
        Dictionary(grouping: addresses, by: \.target).mapValues { $0.map(\.threadID) }
    }

    func setFolded(_ isFolded: Bool, project key: String, in window: ChatWindowModel) {
        drawerPreferences.setFolded(isFolded, project: key, among: presentProjects(in: window))
    }

    func setAllSectionsFolded(_ isFolded: Bool, in window: ChatWindowModel) {
        drawerPreferences.setAllFolded(isFolded, projects: drawerPreferences.mode == .projects ? presentProjects(in: window) : [])
    }

    private func presentProjects(in window: ChatWindowModel) -> Set<String> {
        var arrangement = unfoldedArrangement(in: window)
        arrangement.mode = .projects
        let now = Date.now
        let items = sidebarItems(sidebarInputs(in: window), in: window, layout: .live(at: now), arrangement: arrangement,
                                 now: now)
        var keys: Set<String> = []
        for case let .project(header) in items { keys.insert(header.key) }
        return keys
    }

    // MARK: - Row actions

    /// Selecting a row selects its owning host. Re-selecting the conversation
    /// that host already has open only switches the visible model.
    @discardableResult
    func selectConversation(at address: ConversationAddress) -> Task<Void, Never>? {
        guard let screen = screen(for: address.hostID) else { return nil }
        let alreadyOpen = screen.openThreadID == address.threadID
        select(target: address.target)
        guard alreadyOpen == false else { return nil }
        #if os(macOS) && RC_PERF_HARNESS
        if let fixture = screen.target.switchFixtures[address.threadID] {
            screen.resumeConversation(fixture.header)
            return nil
        }
        #endif
        guard let thread = screen.target.conversationList.threads.first(where: { $0.id == address.threadID }) else {
            return screen.openConversation(threadID: address.threadID)
        }
        screen.resumeConversation(thread)
        return nil
    }

    func selectWorkingDirectory(_ path: String, on screen: ChatScreenModel, ifStillShowing contextID: UUID) {
        guard isShown(screen), screen.currentConversationID == contextID else { return }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, screen.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) != path else { return }
        if screen.shownNewChatDraft != nil { return screen.selectWorkingDirectory(path) }
        guard let fresh = startNewConversation(onHostID: screen.hostID) else { return }
        fresh.selectWorkingDirectory(path)
    }

    var favoriteFolders: [FavoriteFolder] {
        FavoriteFolder.list(settings.hosts.compactMap { model(for: $0.id)?.favoriteFolderHost })
    }

    func syncFavoriteFolders() {
        for host in settings.hosts { model(for: host.id)?.directories.syncFavorites() }
    }

    static let syncedPreferenceKeys = ModelPickerPreferences.syncedKeys
        .union(NewChatDefaults.syncedKeys)
        .union(TranscriptionSettings.syncedKeys)
        .union(ConversationDrawerPreferences.syncedKeys)
        .union(VoiceCall.syncedPreferenceKeys)
        .union([SpeechPreferences.autoSpeakKey, AppThemeStorage.selectedThemeIDKey, AccountNameStore.storageKey])

    private var connectedHostModels: [ChatTargetModel] {
        settings.hosts.compactMap { model(for: $0.id) }.filter(\.isGatewayConnected)
    }

    private func syncPreferences() {
        for model in connectedHostModels { model.hostServices.preferenceExchange.sync() }
    }

    func reloadSyncedPreferences() {
        modelPickerPreferences.reload()
        drawerPreferences.reloadMode()
        accountDirectory.names.reload()
        transcriptionSettings.reload()
        let speech = SpeechPreferences.shared
        let wasAutoSpeaking = speech.isAutoSpeakEnabled
        speech.reload()
        if wasAutoSpeaking, !speech.isAutoSpeakEnabled {
            for model in models { model.speech.cancel() }
        }
    }

    func selectFavorite(_ favorite: FavoriteFolder, from screen: ChatScreenModel, ifStillShowing contextID: UUID) {
        guard favorite.hostID != screen.hostID else {
            return selectWorkingDirectory(favorite.path, on: screen, ifStillShowing: contextID)
        }
        guard selectedScreen === screen, screen.currentConversationID == contextID,
              let destination = self.screen(for: favorite.hostID)
        else { return }
        select(target: destination.executionTarget)
        guard selectedScreen === destination else { return }
        if destination.showsUnsentContent, destination.workingDirectory != favorite.path {
            destination.startNewConversation()
        }
        selectWorkingDirectory(favorite.path, on: destination, ifStillShowing: destination.currentConversationID)
    }

    func removeFavorite(_ favorite: FavoriteFolder) {
        model(for: favorite.hostID)?.directories.removeFavorite(favorite.path)
    }

    enum ConversationSwitchOutcome: Equatable {
        case refusedWhileDictating, unchanged, changed, shownInAnotherWindow
    }

    var refusesSwitchWhileDictating: Bool { selectedModel?.voice.isRecording == true }

    func switchConversation(to address: ConversationAddress) -> ConversationSwitchOutcome {
        let address = ConversationAddress(hostID: settings.canonicalHostID(address.hostID), threadID: address.threadID)
        let span = PerfBuild.span("switch.request"); defer { span.end() }
        let isShowing = isShowingConversation(at: address, on: selectedScreen)
        if !isShowing, refusesSwitchWhileDictating { return .refusedWhileDictating }
        supersedePendingNavigation()
        if !isShowing, events.focusWindow(presenting: .conversation(address), besides: keyWindow.id) {
            return .shownInAnotherWindow
        }
        conversationSwitch = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let span = PerfBuild.span("switch.commit"); defer { span.end() }
            conversationSwitch = nil
            guard isShowingConversation(at: address, on: selectedScreen) || !refusesSwitchWhileDictating else { return }
            selectConversation(at: address)
        }
        return isShowing ? .unchanged : .changed
    }

    func isShowingConversation(at address: ConversationAddress, on screen: ChatScreenModel?) -> Bool {
        screen?.openAddress == address
    }

    func openAgentConversation(_ agent: ConversationAgent, from parent: ConversationAddress) async throws {
        guard let threadID = agent.threadId, agent.capabilities.openConversation else {
            throw ConversationAgentNavigationError.noConversation
        }
        let owner = try activeOwner(hostID: agent.ownerHostId ?? parent.hostID)
        supersedePendingNavigation()
        let generation = navigationGeneration
        let header: ConversationHeader
        do {
            header = try await agentThreadHeader(threadID, on: owner.target)
        } catch {
            guard navigationIsCurrent(generation) else { return }
            throw error
        }
        guard navigationIsCurrent(generation) else { return }
        guard !owner.isRetired else { throw CancellationError() }
        let child = ConversationAddress(hostID: agent.ownerHostId ?? parent.hostID, threadID: threadID)
        owner.resumeConversation(header)
        select(target: child.target)
        agentNavigation = AgentNavigation(parent: parent, child: child)
    }

    func returnToAgentParent() async throws {
        guard let navigation = agentNavigation else { return }
        let owner = try activeOwner(hostID: navigation.parent.hostID)
        let header = try await agentThreadHeader(navigation.parent.threadID, on: owner.target)
        guard !owner.isRetired, isShowingConversation(at: navigation.child, on: selectedScreen) else { return }
        owner.resumeConversation(header)
        select(target: navigation.parent.target)
        agentNavigation = nil
    }

    func sendToAgentParent(_ request: String, from parent: ConversationAddress) async throws {
        let owner = try activeOwner(hostID: parent.hostID)
        if owner.activeSessionID != parent.threadID {
            let header = try await agentThreadHeader(parent.threadID, on: owner.target)
            guard !owner.isRetired else { throw CancellationError() }
            owner.resumeConversation(header)
        }
        select(target: parent.target)
        if let document = owner.composerDocument {
            let text = (document.isEmpty ? "" : "\n\n") + request
            try await document.apply(.append(.init(runs: [.text(text)])))
        }
    }

    func performAgentAction(_ action: ConversationAgentAction, on agent: ConversationAgent, in parent: ConversationAddress, text: String, mutationID: UUID) async throws {
        let owner = try activeOwner(hostID: agent.ownerHostId ?? parent.hostID)
        let threadID = agent.ownerThreadId
        try await owner.target.gatewayClient.agentAction(threadID: threadID, agent: agent, action: action, text: text, mutationID: mutationID)
    }

    func moveAgent(_ address: ConversationAddress, under parent: ConversationAddress?) async throws {
        guard let owner = model(for: address.hostID), owner.acceptsWork else { throw ConversationAgentNavigationError.hostUnavailable }
        try await owner.gatewayClient.setAgentParent(agent: .init(hostId: address.hostID, threadId: address.threadID),
            parent: parent.map { .init(hostId: $0.hostID, threadId: $0.threadID) })
        try Task.checkCancellation()
        guard !owner.isRetired else { throw CancellationError() }
        await owner.conversationList.applyParent(parent, to: address.threadID)
        await owner.conversationList.refresh(reason: "agent placement changed")
        for model in models { model.invalidateAgentLists() }
    }

    func agentParentCandidates(excluding address: ConversationAddress, query: String) async -> [(address: ConversationAddress, title: String, hostName: String)] {
        let inputs = models.map { ($0.hostID, $0.hostDisplayName, $0.conversationList.threads) }
        return await Self.prepareParentCandidates(inputs, excluding: address, query: query)
    }

    @concurrent private static func prepareParentCandidates(_ inputs: [(UUID, String, [ConversationHeader])],
        excluding address: ConversationAddress, query: String) async -> [(address: ConversationAddress, title: String, hostName: String)] {
        var candidates: [(address: ConversationAddress, title: String, hostName: String)] = []
        for (hostID, name, headers) in inputs {
            for header in headers {
                guard !Task.isCancelled else { return [] }
                let candidate = ConversationAddress(hostID: hostID, threadID: header.id)
                if candidate != address, query.isEmpty || header.displayTitle.localizedStandardContains(query) || name.localizedStandardContains(query) {
                    candidates.append((candidate, header.displayTitle, name))
                }
            }
        }
        return candidates
    }

    private func activeOwner(hostID: UUID) throws -> ChatScreenModel {
        guard let owner = screen(for: hostID), !owner.isRetired else {
            throw ConversationAgentNavigationError.hostUnavailable
        }
        return owner
    }

    private func agentThreadHeader(_ threadID: String, on owner: ChatTargetModel) async throws -> ConversationHeader {
        let header = try await ConversationHeader.prepare(owner.gatewayClient.readThread(threadID: threadID, includeTurns: false).thread)
        try Task.checkCancellation()
        return header
    }

    @discardableResult
    func startNewConversation(onHostID hostID: UUID) -> ChatScreenModel? {
        let source = selectedScreen
        guard let destination = startNewConversation(provider: newChatProvider, preferredHostID: hostID) else { return nil }
        if source?.hostID == destination.hostID, let directory = source?.workingDirectory {
            destination.suggestWorkingDirectory(directory)
        }
        return destination
    }

    @discardableResult
    func startNewConversation(provider: AgentProvider, preferredHostID: UUID?) -> ChatScreenModel? {
        guard let destination = newConversationDestination(preferredHostID: preferredHostID) else { return nil }
        destination.startNewConversation()
        if destination.currentAgentProvider != provider {
            destination.selectDefaultModel(for: provider)
        }
        select(target: destination.executionTarget)
        return destination
    }

    func selectModel(_ option: ModelOption) {
        guard !isQuiescing, let screen = selectedScreen, screen.target.acceptsWork else { return }
        guard screen.activeSessionID != nil || !screen.isCurrentConversationBusy else {
            screen.present(.conversation("Wait for this chat to connect before changing its model."))
            return
        }
        screen.selectModel(option, for: screen.activeSessionID)
    }

    func send(from source: ChatScreenModel) async -> Bool {
        guard !isQuiescing else { return false }
        guard source === selectedScreen else {
            logger.error("send refused: source is not the key window's screen key=\(self.keyWindow.logID) source=\(source.executionTarget.id)|\(source.openThreadID ?? "none")")
            return false
        }
        return await source.send()
    }

    func queue(from source: ChatScreenModel) async -> Bool {
        guard !isQuiescing, source === selectedScreen, source.activeSessionID != nil else { return false }
        return await source.queue()
    }

    private struct WindowEventUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func prepareWindowForExternalEvent(_ event: ExternalEvent, in window: ChatWindowModel, admittedGeneration: UUID) async throws {
        try Task.checkCancellation()
        guard !isQuiescing, window.isAttached, navigationGeneration == admittedGeneration else { throw CancellationError() }
        let generation = admittedGeneration
        var destination = readyTarget(for: event, in: window)
        if destination == nil {
            await accountMigration?.value
            await accountDirectory.restore()
            try Task.checkCancellation()
            destination = readyTarget(for: event, in: window)
        }
        try Task.checkCancellation()
        guard !isQuiescing, window.isAttached, navigationGeneration == generation else { throw CancellationError() }
        guard let destination, destination.acceptsWork else {
            if case .presentVoiceCall = event { throw CancellationError() }
            if case .open(.conversation) = event {
                throw WindowEventUnavailable(message: "This conversation's host is unavailable.")
            }
            if case .open(.unsentDraft) = event {
                throw WindowEventUnavailable(message: "This draft's host is unavailable.")
            }
            if let failure = draftRetirementFailure(for: window.selectedTarget) {
                throw WindowEventUnavailable(message: failure.message)
            }
            throw WindowEventUnavailable(message: settings.hosts.isEmpty
                ? "Add a gateway host before starting a chat."
                : "No gateway host is ready for a new chat.")
        }
        if window.screen(for: destination.target) == nil { installScreen(of: destination, in: window) }
        window.select(destination.target)
        if keyWindow === window { mirrorKeySelection() }
        applyVisibility()
        prepare(target: destination.target)
    }

    private func readyTarget(for event: ExternalEvent, in window: ChatWindowModel) -> ChatTargetModel? {
        if case .open(.conversation(let address)) = event {
            guard let target = model(for: address.hostID), target.acceptsWork else { return nil }
            return target
        }
        if case .open(.unsentDraft(let address)) = event {
            guard let target = model(for: address.target.hostID),
                  target.acceptsWork else { return nil }
            return target
        }
        if case .presentVoiceCall(let callID) = event {
            guard voiceCalls.call.liveCallID == callID, let owner = voiceCalls.call.callOwner,
                  let target = model(for: owner.hostID), target.acceptsWork else { return nil }
            return target
        }
        if case .quickAction(let request) = event, request.action == .voiceChat,
           let owner = voiceCalls.call.callOwner {
            guard let target = model(for: owner.hostID), target.acceptsWork else { return nil }
            return target
        }
        let preferred = window.selectedTarget?.hostID
        let hostIDs = preferred.map { [$0] } ?? []
        for hostID in hostIDs + settings.hosts.map(\.id).filter({ $0 != preferred }) {
            if let target = newConversationTarget(preferredHostID: hostID), target.acceptsWork { return target }
        }
        return nil
    }

    private func newConversationDestination(preferredHostID: UUID?) -> ChatScreenModel? {
        newConversationTarget(preferredHostID: preferredHostID).flatMap { keyWindow.screen(for: $0.target) }
    }

    private func newConversationTarget(preferredHostID: UUID?) -> ChatTargetModel? {
        (preferredHostID ?? selectedHostID).flatMap { model(for: $0) }
    }

    var codexModelCatalog: CodexModelCatalogSourceState {
        guard !settings.hosts.isEmpty else { return .noHosts }
        guard let owner = newConversationTarget(preferredHostID: selectedHostID) else { return .hostUnavailable }
        let service = owner.codexModels
        return .available(CodexModelCatalogSource(
            service: service,
            sourceLabel: owner.hostDisplayName,
            refresh: { await owner.refreshCodexModels() }))
    }

    func readNewChatModelCatalog<Result: Sendable>(_ read: @MainActor () throws -> Result) async throws -> Result {
        let owner = newConversationTarget(preferredHostID: selectedHostID)
        await owner?.restoreCachedCodexModels()
        try Task.checkCancellation()
        guard owner?.isRetired != true,
              newConversationTarget(preferredHostID: selectedHostID) === owner else {
            throw CancellationError()
        }
        return try read()
    }

    func newChatModelOptions(preferredHostID: UUID?) -> [ModelOption] {
        AgentProvider.allCases.flatMap { provider in
            newConversationTarget(preferredHostID: preferredHostID)?
                .modelOptions(for: provider) ?? []
        }
    }

    func modelOptions(for screen: ChatScreenModel) -> [ModelOption] {
        guard screen.activeSessionID == nil else { return screen.selectedModel.map(screen.pickerModelOptions(for:)) ?? [] }
        let options = newChatModelOptions(preferredHostID: screen.hostID)
        guard let selected = screen.selectedModel, !options.contains(where: { $0.id == selected.id }) else { return options }
        return options + [selected]
    }

    var newChatProvider: AgentProvider {
        let preferredID = NewChatDefaults.preferredModelID(defaults: defaults)
        return preferredID.map(AgentProvider.provider(forModelID:)) ?? .codex
    }

    func newChatDefaultModel() -> NewChatModelLookup {
        newChatLookup(provider: newChatProvider) { $0.newChatDefaultModel() }
    }

    func configuredModel(id: String) -> NewChatModelLookup {
        newChatLookup(provider: AgentProvider.provider(forModelID: id)) { $0.configuredModel(id: id) }
    }

    private func newChatLookup(
        provider: AgentProvider, _ lookup: (ChatTargetModel) -> NewChatModelLookup
    ) -> NewChatModelLookup {
        newConversationTarget(preferredHostID: selectedHostID).map(lookup) ?? .hostUnavailable(provider)
    }

    func forkConversation(at address: ConversationAddress) async {
        guard let screen = screen(for: address.hostID),
              let thread = screen.target.conversationList.threads.first(where: { $0.id == address.threadID })
        else { return }
        select(target: address.target)
        await screen.forkConversation(thread)
    }

    func regenerateTitle(at address: ConversationAddress, onFailure: @escaping @MainActor (String) -> Void) {
        model(for: address.hostID)?.regenerateTitle(threadID: address.threadID, onFailure: onFailure)
    }

    func pin(_ address: ConversationAddress, name: String) {
        drawerPreferences.isPinnedFolded = false
        model(for: address.hostID)?.conversationList.pin(threadID: address.threadID, name: name)
    }

    func unpin(_ address: ConversationAddress) {
        model(for: address.hostID)?.conversationList.unpin(threadID: address.threadID)
    }

    func pinnedName(for address: ConversationAddress) -> String? {
        return model(for: address.hostID)?.conversationList.pinnedName(for: address.threadID)
    }

    // MARK: - Completion notifications

    var openConversationAddress: ConversationAddress? {
        guard let visible = selectedScreen, !visible.isRetired else { return nil }
        return visible.openAddress
    }

    private func notificationIsOpen(_ payload: TaskCompletionNotificationPayload) -> Bool {
        ForegroundNotificationPresentation.isOpen(payload, address: openConversationAddress)
    }

    // MARK: - Launch restore

    var openLocation: LaunchLocation? {
        guard let visible = selectedScreen, !visible.isRetired else { return nil }
        if let address = visible.openAddress { return .conversation(address) }
        return visible.shownNewChatDraft.map { .newChat(UnsentDraftAddress(target: visible.executionTarget, draftID: $0)) }
    }

    private func openConversationDidChange() {
        notifications.dismissIfOpen(notificationIsOpen)
        launchRestore.record(openLocation)
    }

    var hasPendingNotificationTap: Bool { events.hasPendingCompletionTap }

    func launchOwner(of address: ConversationAddress) -> ChatTargetModel? {
        model(for: address.hostID)
    }

    func showRestored(_ thread: ConversationHeader, on owner: ChatTargetModel, at address: ConversationAddress) {
        keyWindow.screen(for: owner.target)?.resumeConversation(thread)
        select(target: address.target)
    }

    func showRestoredNewChat(on target: ExecutionTarget) {
        guard keyWindow.selectedTarget != target else { return }
        select(target: target)
    }

    func receiveNotification(_ delivery: ForegroundNotificationPresentation.Delivery,
                             applicationIsActive: Bool) -> ForegroundNotificationPresentation.Disposition {
        notifications.receive(delivery, applicationIsActive: applicationIsActive, isOpen: notificationIsOpen)
    }

    func handleCompletionNotificationTap(payloadJSON: String) async {
        await runNotificationNavigation { [weak self] generation in
            let delivery = await ForegroundNotificationPresentation.prepare(payloadJSON: payloadJSON, title: "", body: "")
            guard let self, self.navigationIsCurrent(generation) else { return }
            guard let payload = delivery.payload else {
                guard await self.dismissCoverForNotification(payload: nil, generation: generation) else { return }
                guard self.navigationIsCurrent(generation) else { return }
                self.logger.error("notification tap payload unreadable field=\(delivery.decodingFailure ?? "root")")
                self.notificationRoutingError = "This notification has no readable conversation identity. Open History to choose a conversation."
                return
            }
            await self.routeCompletionNotification(payload, generation: generation)
        }
    }

    func supersedePendingNavigation() {
        keyWindow.cancelComposerFocus()
        guard !isCommittingNotificationNavigation else { return }
        selectedScreen?.cancelPendingConversationOpen()
        navigationGeneration = UUID()
        notificationNavigationTask?.cancel()
        notificationNavigationTask = nil
        conversationSwitch?.cancel()
        conversationSwitch = nil
        launchRestore.settle(recording: openLocation)
    }

    func handleCompletionNotificationTap(payload: TaskCompletionNotificationPayload) async {
        await runNotificationNavigation { [weak self] generation in
            await self?.routeCompletionNotification(payload, generation: generation)
        }
    }

    private func runNotificationNavigation(_ operation: @escaping @MainActor (UUID) async -> Void) async {
        guard !isQuiescing else { return }
        supersedePendingNavigation()
        notificationRoutingError = nil
        let generation = navigationGeneration
        let task = Task { await operation(generation) }
        notificationNavigationTask = task
        await task.value
        if navigationGeneration == generation { notificationNavigationTask = nil }
    }

    private func navigationIsCurrent(_ generation: UUID) -> Bool {
        !isQuiescing && !Task.isCancelled && navigationGeneration == generation
    }

    private func routeCompletionNotification(_ payload: TaskCompletionNotificationPayload, generation: UUID) async {
        _ = notifications.consume(payload)
        notifications.dismiss()
        guard await dismissCoverForNotification(payload: payload, generation: generation) else { return }
        guard navigationIsCurrent(generation) else { return }
        guard let sessionID = payload.sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notificationRoutingError = "This notification has no conversation identity. Open History to choose a conversation."
            return
        }

        await accountMigration?.value
        guard navigationIsCurrent(generation) else { return }
        guard let target = TaskCompletionRouting.resolve(
            payloadHostID: settings.canonicalHostID(payload.hostID),
            targets: models.map(\.target)
        ) else {
            // Deliberately no fallback to the visible host: a smart match by
            // time, directory and prompt preview would open a same-looking chat
            // on a gateway that never ran the turn.
            notificationRoutingError = """
                No configured gateway knows that conversation. Open History and pick the right host.
                """
            return
        }
        guard let owner = model(for: target.hostID) else { return }
        let address = ConversationAddress(hostID: target.hostID, threadID: sessionID)
        do {
            // Reading may finish after a newer user navigation. It cannot
            // mutate either model selection or question focus until fenced.
            let thread = try await loadConversationHeader(owner, address.threadID)
            guard navigationIsCurrent(generation), thread.id == address.threadID,
                  !owner.isRetired, model(for: target.hostID) === owner else { return }
            isCommittingNotificationNavigation = true
            defer { isCommittingNotificationNavigation = false }
            let ownerScreen = keyWindow.screen(for: owner.target)
            ownerScreen?.resumeConversation(thread)
            select(target: address.target)
            if let itemID = payload.questionItemID {
                ownerScreen?.requestQuestionFocus(itemID: itemID)
            }
        } catch {
            guard navigationIsCurrent(generation) else { return }
            notificationRoutingError = "Couldn't open the notification conversation: \(error.localizedDescription)"
        }
    }

    private func dismissCoverForNotification(payload: TaskCompletionNotificationPayload?, generation: UUID) async -> Bool {
        let sceneGeneration = notificationSceneGeneration
        let dismissed = await notificationSurfaces.dismissCoverOnKeySurface()
        guard navigationIsCurrent(generation) else { return false }
        guard dismissed else {
            // A retry is foreground presentation. An explicit OS tap may still
            // navigate while activating, but a suspended foreground retry must
            // not survive an inactive/background transition or replay later.
            guard notificationApplicationIsActive(),
                  notificationSceneGeneration == sceneGeneration else { return false }
            // The same scene-level owner remains visible over the refused
            // presentation, and the original exact target remains retryable.
            notifications.present(.init(isConversationAlert: true, title: "Couldn't open notification",
                body: "Close the current view, then tap to try again or choose the conversation in History.",
                payload: payload, decodingFailure: nil))
            return false
        }
        return true
    }
}

struct VoiceCallUnavailable: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String

    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
