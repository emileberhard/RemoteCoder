import Foundation
import Observation
import OSLog
import PhotosUI
import SpeechKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatTargetModel: GatewayEventSink, TranscriptRecoverySource, ConversationWarmingHost, TurnDispatchHost,
    VoiceCallHost, DictationHost {
    @ObservationIgnored private var registeredScreens: [WeakScreen] = []
    private struct WeakScreen { weak var screen: ChatScreenModel? }
    static let presentingScreenCapacity = 8
    private static let routeMoveInterval = Duration.seconds(30)
    private static let deferredRouteMoveDelay = Duration.seconds(1)
    @ObservationIgnored lazy var conversationWarmer = ConversationWarmer(host: self, conversations: conversations, history: historyService)
    @ObservationIgnored var recentConversations = RecentConversationCache(capacity: 8)
    #if os(macOS) && RC_PERF_HARNESS
    @ObservationIgnored var switchFixtures: [String: SwitchFixture] = [:]
    #endif
    @ObservationIgnored private var activityReadRequested = false

    @ObservationIgnored private let logger = Logger(
        subsystem: "RemoteCoder",
        category: "CodexChat"
    )

    /// The one gateway host this model speaks to for its whole lifetime.
    ///
    /// Every runtime dictionary here is keyed by thread/turn id, which is only
    /// unique within a host; rebinding a live model to another address is what
    /// made turns, resumes and recovery cross machines.
    @ObservationIgnored let host: GatewayHostConfiguration
    @ObservationIgnored let hostServices: HostServices
    let fileOpener: HostFileOpener
    var target: ExecutionTarget { ExecutionTarget(hostID: hostID) }
    var hostID: UUID { host.id }
    /// Follows a settings rename without retiring the connection.
    private(set) var hostDisplayName: String

    @ObservationIgnored let sessionIndex: ConversationIndex
    @ObservationIgnored private let gateway: GatewayClient
    @ObservationIgnored let turnStops: TurnStops
    @ObservationIgnored lazy var dispatcher = TurnDispatcher(
        host: self, gateway: gateway, turns: turns, stops: turnStops, conversations: conversations,
        sessionIndex: sessionIndex, metadata: metadataService, drafts: drafts)
    @ObservationIgnored let historyService: GatewayHistoryService
    @ObservationIgnored let metadataService: ConversationMetadataService
    private(set) var metadataStatus = SessionMetadataStatus()
    var gatewayWarning: GatewayWarning?
    private(set) var isResolvingMetadata = false

    @ObservationIgnored let voiceHistoryStore: RealtimeVoiceHistoryStore
    @ObservationIgnored let directories: HostDirectories
    @ObservationIgnored private let directoryVisibilityOwner = UUID()

    @ObservationIgnored private var lifecycle = TargetLifecycle()
    /// The workspace shows one model at a time; hidden models keep working but
    /// must not publish device-wide state such as the foreground session marker.
    var isVisible: Bool { lifecycle.presentation.presented && !lifecycle.isRetired }
    @ObservationIgnored private var feedbackVisibilityGeneration = 0
    @ObservationIgnored private let haptics: HapticService
    /// A removed or reconfigured host retires its model; late async work must
    /// not restart polling or publish into its replacement.
    var isRetired: Bool { lifecycle.isRetired }
    var acceptsWork: Bool { lifecycle.acceptsWork }
    @ObservationIgnored private var terminationTask: Task<[String], Never>?
    @ObservationIgnored private(set) var pendingTerminationOperation: String?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private let preparation = TargetPreparation()
    @ObservationIgnored private var metadataConnectionID: UUID?
    @ObservationIgnored private var routeMoveLoop: Task<Void, Never>?
    @ObservationIgnored private var routeMoveRunning = false
    @ObservationIgnored private var routeMoveRequested = false
    var isPrepared: Bool {
        #if os(macOS) && RC_PERF_HARNESS
        if PerfBuild.isDisabled("lifetimePreparation") { return false }
        #endif
        return preparation.isPrepared
    }
    private enum OwnedTask: Hashable {
        #if os(macOS) && RC_PERF_HARNESS
        case preparation
        #endif
        case lifecycle, metadataStatus, metadataAction, inventoryRefresh, scheduledActivityRead
        case conversationActivity, historyAutoRefresh, historyInvalidation(String), warmConversations
        case routeMove, codexModelCacheLoad, codexModelRefresh, takeOver, marksSync, historyHeaderRecovery, historyRetry
        case titleRegeneration(String)
        #if os(iOS)
        case liveActivitySync
        case liveActivityRead
        #endif
    }
    /// Turn dispatch is unstructured on purpose — a send must outlive the view
    /// that started it — so the model owns the handles and cancels them when its
    /// host is removed or reconfigured.
    @ObservationIgnored private let ownedTasks = OwnedTasks<OwnedTask>()
    @ObservationIgnored private var connectionState: GatewayEventPump.Link?
    /// Supersedes pending workspace navigation when another conversation opens.
    @ObservationIgnored var onConversationNavigation: (@MainActor () -> Void)?
    /// Set by the workspace to retire a banner when its conversation is opened.
    @ObservationIgnored var onActiveSessionChange: (@MainActor (ChatTargetModel) -> Void)?

    let turns = TurnRegistry()

    @ObservationIgnored private lazy var eventPump = GatewayEventPump(gateway: gateway, conversations: conversations, sink: self)
    @ObservationIgnored private var scheduledActivityDue: ContinuousClock.Instant?
    @ObservationIgnored private var activitySnapshotVersion: (epoch: String, revision: UInt64)?
    @ObservationIgnored private var activityReadFailures = 0
    #if os(iOS)
    @ObservationIgnored private let liveActivityService: ActiveTasksLiveActivityService
    #endif
    private var isInBackground: Bool { lifecycle.isBackgrounded }
    private var isSceneActive: Bool { lifecycle.isSceneLive }
    var isSceneLive: Bool { lifecycle.isSceneLive }
    private var isVoiceModeActive: Bool { lifecycle.voiceCallActive }
    @ObservationIgnored private let backgroundExecution: any BackgroundExecution
    @ObservationIgnored let chatDefaults: UserDefaults
    let drafts: ComposerDraftStore
    let fileImports: FileAttachmentImports

    var activeSessionID: String? { primaryScreen?.activeSessionID }
    var historyBusySessionIDs: Set<String> { turns.busyThreadIDs }

    var historyActivityStates: [String: CodexGatewayDaemon.ActivityState] {
        let managed = historyBusySessionIDs
        let ids = Set(conversationList.threads.map(\.id)).union(managed)
        let states = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, conversationActivity.state(for: $0, hasManagedTurn: managed.contains($0)))
        })
        return states
    }

    func historyActivityState(of threadID: String) -> CodexGatewayDaemon.ActivityState {
        conversationActivity.state(for: threadID, hasManagedTurn: historyBusySessionIDs.contains(threadID))
    }

    var conversationActivity = ConversationActivity()

    private func markActivityUnavailable() {
        conversationActivity = ConversationActivity()
        turns.clearAllMissing()
    }

    func dismissStopFailure() {
        turnStops.dismissFailure()
    }

    struct ConversationTakeOver: Equatable {
        let threadID: String
        var failure: String?
    }

    private(set) var takeOver: ConversationTakeOver?

    func takeOverConversation(threadID: String) {
        guard acceptsWork, takeOver == nil || takeOver?.failure != nil else { return }
        let feedback = feedbackForCurrentConversation()
        takeOver = ConversationTakeOver(threadID: threadID)
        logger.notice("take over requested thread=\(threadID, privacy: .public)")
        ownedTasks.start(.takeOver) { [weak self] in
            guard let self else { return }
            do {
                try await self.gateway.takeOverConversation(threadID: threadID)
                try Task.checkCancellation()
                await self.fetchActiveTurnsOnce()
                self.takeOver = nil
                feedback(.success)
            } catch is CancellationError {
                self.takeOver = nil
            } catch {
                self.logger.error("take over failed thread=\(threadID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.takeOver = ConversationTakeOver(threadID: threadID, failure: error.localizedDescription)
                feedback(.error)
            }
        }
    }

    func regenerateTitle(threadID: String, onFailure: @escaping @MainActor (String) -> Void) {
        guard acceptsWork, !ownedTasks.isRunning(.titleRegeneration(threadID)) else { return }
        logger.notice("title regeneration requested thread=\(threadID, privacy: .public)")
        ownedTasks.start(.titleRegeneration(threadID)) { [weak self] in
            guard let self else { return }
            do {
                try await self.gateway.regenerateTitle(threadID: threadID)
                self.haptics.play(.success)
            } catch is CancellationError {
            } catch {
                self.logger.error("title regeneration failed thread=\(threadID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.haptics.play(.error)
                onFailure(error.localizedDescription)
            }
        }
    }

    func dismissTakeOverFailure() {
        if takeOver?.failure != nil { takeOver = nil }
    }

    func turnsChanged(_ change: TurnRegistryChange) {
        requestAddedQuestionScopes()
        turnStops.retain(running: turns.runningTurns)
        if change.countBefore != change.countAfter {
            logger.notice(
                "active tasks changed old=\(change.countBefore, privacy: .public) new=\(change.countAfter, privacy: .public) summary=\(self.liveActivityDebugSummary(), privacy: .public)"
            )
        }
        if change.countAfter < change.countBefore { scheduleRouteMove() }
        run(lifecycle.handle(.activeWorkChanged(count: turns.liveActivityTaskCount)))
    }

    var questionAskTimesByThreadID: [String: [Int64]] {
        questions.pendingAskTimesByThreadID.keys.reduce(into: [:]) { times, threadID in
            times[threadID] = questionAskTimes(of: threadID)
        }
    }
    func questionAskTimes(of threadID: String) -> [Int64] {
        let marks = conversationList.marks
        return (questions.pendingAskTimesByThreadID[threadID] ?? [])
            .filter { marks.isUnseenQuestion(askedAtMs: $0, in: threadID) }.map { $0 / 1000 }
    }
    func waitingSinceByThreadID(in states: [String: CodexGatewayDaemon.ActivityState]) -> [String: Int64] {
        states.reduce(into: [:]) { times, entry in
            if entry.value == .waiting, let since = conversationActivity.waitingSince(for: entry.key) { times[entry.key] = since }
        }
    }
    func waitingSince(of threadID: String) -> Int64? {
        historyActivityState(of: threadID) == .waiting ? conversationActivity.waitingSince(for: threadID) : nil
    }
    var newestRequestTimesByThreadID: [String: Int64] {
        questionAskTimesByThreadID.compactMapValues { $0.max() }
            .merging(waitingSinceByThreadID(in: historyActivityStates), uniquingKeysWith: max)
    }
    @ObservationIgnored lazy var questions = QuestionReplica(
        hostID: hostID, remote: gateway, sessions: conversations,
        presentedPrompt: { [weak self] address in self?.screens.lazy.compactMap { $0.questionPrompt(for: address) }.first })

    /// Off-main pre-parsed presentation per message; bubbles only display.
    let renderedMessages = RenderedMessageStore()
    @ObservationIgnored let conversations: ConversationSessions
    let observation: ConversationObservationCoordinator
    @ObservationIgnored private var activityRevision: UInt64 = 0

    private var isHistoryDrawerOpen: Bool { lifecycle.presentation.drawerOpen }
    let codexModels: CodexModelCatalogService
    @ObservationIgnored let modelCatalog: TargetModelCatalog
    let modelPickerPreferences: ModelPickerPreferences
    var codexModelVisibility: ModelVisibility { modelPickerPreferences.codexModelVisibility }

    var voice: VoiceInputController
    var voiceError: String?
    var speech: VoiceOutputController
    @ObservationIgnored let realtimeVoice: VoiceCall
    @ObservationIgnored let gatewayPolicy: SharedGatewayPolicy

    private(set) var gatewayConnectivity = GatewayConnectivity.disconnected
    var gatewayRoute: GatewayRoute.Kind? { gatewayConnectivity.route }
    var isGatewayConnected: Bool { gatewayRoute != nil }

    @ObservationIgnored private lazy var transcriptRecovery = TranscriptRecovery(source: self)

    var remoteHomePath: String? { directories.lastKnownHomePath }

    var favoriteFolderHost: FavoriteFolder.Host {
        FavoriteFolder.Host(id: hostID, name: hostDisplayName, paths: directories.favorites, remoteHomePath: remoteHomePath)
    }

    var favoriteFolders: [FavoriteFolder] { FavoriteFolder.list([favoriteFolderHost]) }

    var conversationList: ConversationList

    func modelOptions(for provider: AgentProvider) -> [ModelOption] {
        modelCatalog.options(for: provider)
    }
    func pickerModelOptions(for selection: ModelOption) -> [ModelOption] {
        modelCatalog.pickerOptions(including: selection)
    }
    func newChatDefaultModel() -> NewChatModelLookup {
        modelCatalog.newChatDefault()
    }
    func configuredModel(id: String) -> NewChatModelLookup {
        modelCatalog.configured(id: id)
    }

    private func refreshQuestionScopes() {
        guard let scopes = questionScopeThreads() else { return }
        questions.requestScopes(scopes)
    }

    private func requestAddedQuestionScopes() {
        guard let scopes = questionScopeThreads() else { return }
        questions.requestAddedScopes(scopes)
    }

    private func questionScopeThreads() -> Set<String>? {
        guard acceptsWork, !isInBackground else { return nil }
        var threads = Array(turns.trackedThreadIDs.sorted().prefix(12))
        if isHistoryDrawerOpen { threads += conversationList.threads.prefix(16).map(\.id) }
        let scoped = Set(threads).union(shownThreadIDs)
        #if os(macOS) && RC_PERF_HARNESS
        return scoped.subtracting(switchFixtures.keys)
        #else
        return scoped
        #endif
    }

    func gatewayQuestionsChanged(_ change: ServerNotification.QuestionsChanged) {
        let threadID = change.threadID
        guard acceptsWork,
              isShown(threadID) || turns.turn(forThread: threadID) != nil ||
                isHistoryDrawerOpen && conversationList.threads.prefix(16).contains(where: { $0.id == threadID }) else { return }
        questions.changed(change)
    }

    func agents(threadID: String) -> ConversationAgentsModel {
        let agents = agentsModel(threadID: threadID)
        recentConversations.record(agents)
        return agents
    }

    private func agentsModel(threadID: String) -> ConversationAgentsModel {
        screens.lazy.compactMap(\.conversationAgents).first { $0.threadID == threadID }
            ?? recentConversations.agents(threadID: threadID)
            ?? ConversationAgentsModel(address: ConversationAddress(hostID: hostID, threadID: threadID),
                                       gateway: gateway)
    }

    private var isOnScreen: Bool { lifecycle.isOnScreen }

    private func reconcileObservation() {
        for screen in screens { screen.publishSeenCompletion() }
        var desired: [String: ConversationSession] = [:]
        if isOnScreen {
            for screen in presentingScreens.prefix(Self.presentingScreenCapacity) {
                guard let thread = screen.activeSessionID, !thread.hasPrefix("claude_"),
                      let session = screen.selectedConversation else { continue }
                desired[thread] = session
            }
        }
        observation.observe(desired)
    }

    private func synchronizeHeaderProtection() {
        let protected = conversationActivity.knownActiveThreadIDs.union(historyBusySessionIDs)
            .union(screens.compactMap(\.activeSessionID))
            .union(screens.compactMap { screen in
                screen.activeConversation?.id == screen.activeSessionID ? screen.activeConversation?.agentParentThreadID : nil
            })
            .union(questionAskTimesByThreadID.compactMap { $0.value.isEmpty ? nil : $0.key })
        if conversationList.setProtectedThreadIDs(protected), !isRetired, !ownedTasks.isRunning(.historyHeaderRecovery) {
            ownedTasks.start(.historyHeaderRecovery) { [weak self] in await self?.conversationList.recoverProtectedHeaders(now: .now) }
        }
    }

    func synchronizeConversationActivity() {
        synchronizeHeaderProtection()
        activityRevision += 1
        guard !ownedTasks.isRunning(.conversationActivity) else { return }
        ownedTasks.start(.conversationActivity) { [weak self] in
            guard let self else { return }
            var applied: UInt64 = 0
            while applied != self.activityRevision, self.acceptsWork, !Task.isCancelled {
                applied = self.activityRevision
                let active = self.turns.runningTurns
                await self.conversations.synchronizeActivity(active)
            }
        }
    }

    @ObservationIgnored var gatewayClient: GatewayClient { gateway }

    /// Previews and tests that do not care which host they talk to.
    convenience init(chatDefaults: UserDefaults = AppStorageScope.current.defaults,
                     modelPickerPreferences: ModelPickerPreferences, syncedPreferences: SyncedPreferenceStore, voiceCalls: VoiceCallCenter,
                     backgroundExecution: any BackgroundExecution, uploadContinuation: any UploadContinuation,
                     gatewayPolicy: SharedGatewayPolicy, storage: HostStorage = .live, htmlVisuals: HTMLVisualServices) {
        self.init(host: GatewayHostConfiguration(id: UUID(), name: "Preview", hostname: "127.0.0.1",
            port: 1, authToken: "preview", transport: .trustedNetwork),
            chatDefaults: chatDefaults, modelPickerPreferences: modelPickerPreferences, syncedPreferences: syncedPreferences,
            voiceCalls: voiceCalls, backgroundExecution: backgroundExecution, uploadContinuation: uploadContinuation,
            gatewayPolicy: gatewayPolicy, storage: storage,
            htmlVisuals: htmlVisuals)
    }

    init(host: GatewayHostConfiguration, chatDefaults: UserDefaults = AppStorageScope.current.defaults,
         modelPickerPreferences: ModelPickerPreferences, syncedPreferences: SyncedPreferenceStore, haptics: HapticService = .shared,
         voiceCalls: VoiceCallCenter, backgroundExecution: any BackgroundExecution, uploadContinuation: any UploadContinuation,
         gatewayPolicy: SharedGatewayPolicy,
         storage: HostStorage = .live, deviceTools: DeviceToolHost? = nil, htmlVisuals: HTMLVisualServices, dictationLibrary: SharedDictationLibrary? = nil) {
        self.backgroundExecution = backgroundExecution
        self.gatewayPolicy = gatewayPolicy
        self.haptics = haptics
        self.realtimeVoice = voiceCalls.call
        self.chatDefaults = chatDefaults
        self.modelPickerPreferences = modelPickerPreferences
        let drafts = ComposerDraftStore(
            directory: storage.directory(for: .target(hostID: host.id)).appending(path: "drafts")
        )
        self.drafts = drafts
        let routes = GatewayRoutes(host: host, directory: storage.directory(for: .host(host.id)),
            relayStorage: KeychainGatewayCredentials(scope: .relayRoute(hostID: host.id)),
            policy: gatewayPolicy, observeLocalNetwork: GatewayRoutes.observeLocalNetwork)
        self.fileImports = FileAttachmentImports(host: host, drafts: drafts, staging: UploadStaging(
            directory: storage.directory(for: .target(hostID: host.id)).appending(path: "upload-staging")
        ), client: GatewayUploadClient(routes: routes), continuation: uploadContinuation)
        self.host = host
        self.hostDisplayName = host.displayName
        let speechAccess = GatewaySpeechAccess(host: host, routes: routes)
        let recordings = storage.root == HostStorage.live.root
            ? DictationRecordingStore<ExecutionTarget>.app
            : DictationRecordingStore<ExecutionTarget>.located(in: storage)
        self.voice = VoiceInputController(access: speechAccess, owner: ExecutionTarget(hostID: host.id),
            transcriber: RemoteCoderTranscriptionService(access: speechAccess), recordings: recordings, haptics: haptics, library: dictationLibrary)
        self.speech = VoiceOutputController(access: speechAccess, preferences: .shared)
        let call = voiceCalls.call
        let callOwner = ExecutionTarget(hostID: host.id)
        let gateway = Self.makeGatewayClient(for: host, routes: routes, deviceTools: deviceTools,
            holdsConnection: { call.isActive(for: callOwner) })
        self.gateway = gateway
        self.turnStops = TurnStops(gateway: gateway)
        let codexModels = CodexModelCatalogService(
            directory: storage.directory(for: .target(hostID: host.id)),
            loadPage: { cursor in try await gateway.listModels(cursor: cursor) }
        )
        self.codexModels = codexModels
        let modelCatalog = TargetModelCatalog(
            service: codexModels,
            preferences: modelPickerPreferences, defaults: chatDefaults)
        self.modelCatalog = modelCatalog
        let hostServices = HostServices(host: host, routes: routes, speech: speechAccess,
            gateway: gateway,
            htmlVisuals: htmlVisuals, syncedPreferences: syncedPreferences, defaults: chatDefaults)
        self.hostServices = hostServices
        self.fileOpener = HostFileOpener(access: hostServices.files, canPreview: HostFileOpener.quickLookCanPreview)
        let historyCache = storage.root == HostStorage.live.root ? HistoryPageCache.shared
            : HistoryPageCache(directory: storage.directory(for: .device).appending(path: "history-pages"))
        let historyService = GatewayHistoryService(gateway: gateway, cache: historyCache)
        self.historyService = historyService
        self.observation = ConversationObservationCoordinator(gateway: gateway, history: historyService, capacity: Self.presentingScreenCapacity)
        let storageDirectory = storage.directory(for: .target(hostID: host.id))
        self.conversationList = ConversationList(
            service: historyService,
            marksRemote: gateway,
            hostID: host.id,
            threadStore: ConversationHeaderStore.scoped(to: ExecutionTarget(hostID: host.id), storage: storage),
            marksStore: ConversationMarksStore(directory: storageDirectory),
            defaults: chatDefaults
        )
        self.metadataService = ConversationMetadataService(
            remote: gateway,
            store: ConversationMetadataStore(hostID: host.id, storage: storage)
        )
        let sessionIndex = ConversationIndex(hostID: host.id, storage: storage)
        self.sessionIndex = sessionIndex
        self.conversations = ConversationSessions(
            hostID: host.id, sessionIndex: sessionIndex, contentSubscriptions: gateway, storage: storage,
            projectionSignposter: AppPerformanceDiagnostics.signposter
        )
        self.voiceHistoryStore = RealtimeVoiceHistoryStore(hostID: host.id, storage: storage)
        self.directories = hostServices.directories
        #if os(iOS)
        self.liveActivityService = hostServices.activities
        #endif
        startCodexModelCacheLoad()
    }

    /// Capture before suspension. Returning to an old host/scene does not revive its feedback.
    func feedbackForCurrentConversation() -> (HapticEvent) -> Void {
        guard let screen = primaryScreen else { return { _ in } }
        let conversationID = screen.currentConversationID
        let visibility = feedbackVisibilityGeneration
        let presentation = screen.transcriptIdentity
        let scene = lifecycle.generation
        let wasVisible = screen.presentation.presented && isSceneActive && acceptsWork
        return { [weak self, weak screen] event in
            guard let self, let screen, wasVisible, self.acceptsWork, screen.presentation.presented, self.isSceneActive,
                  self.feedbackVisibilityGeneration == visibility, self.lifecycle.generation == scene,
                  screen.currentConversationID == conversationID, screen.transcriptIdentity == presentation else { return }
            self.haptics.play(event)
        }
    }

    // MARK: - Lifecycle

    /// Bootstrap suspends many times, and its host can be removed or reconfigured
    /// in between. Every resume rechecks retirement, so a model whose host is gone
    /// cannot restart polling, sync a token or publish into its replacement.
    func prepareIfNeeded() async {
        guard acceptsWork else { return }
        #if os(macOS) && RC_PERF_HARNESS
        if PerfBuild.isDisabled("lifetimePreparation") {
            if !ownedTasks.isRunning(.preparation) {
                ownedTasks.start(.preparation) { [weak self] in await self?.prepareHost() }
            }
            await ownedTasks.value(.preparation)
            return
        }
        #endif
        await preparation.prepare { [weak self] in await self?.prepareHost() }
    }

    private func prepareHost() async {
        guard acceptsWork else { return }
        PerfBuild.count("host.prepareStarted")
        let started = ContinuousClock.now
        logger.notice("host preparation started host=\(self.hostID.uuidString, privacy: .public)")
        _ = lifecycle.handle(.hostPrepared)
        if lifecycle.needsGatewayLoops {
            eventPump.startIfNeeded()
            directories.startIfNeeded()
        }
        startHistoryAutoRefreshIfNeeded()
        guard acceptsWork else { return }

        if remoteHomePath == nil {
            _ = try? await directories.resolveHomePath()
            guard acceptsWork else { return }
        }
        for screen in screens { screen.adoptRemoteHomeAsWorkingDirectoryIfUnset() }

        if !ownedTasks.isRunning(.metadataStatus) {
            let stream = await metadataService.statuses()
            guard acceptsWork else { return }
            ownedTasks.start(.metadataStatus) { [weak self] in
                for await status in stream {
                    guard let self, self.acceptsWork, !Task.isCancelled else { return }
                    self.metadataStatus = status
                }
            }
        }
        let metadataStarted = ContinuousClock.now
        await metadataService.bootstrap()
        guard acceptsWork else { return }
        let metadataMs = metadataStarted.duration(to: .now) / .milliseconds(1)
        let historyStarted = ContinuousClock.now
        await conversationList.bootstrap()
        guard acceptsWork else { return }
        scheduleLiveActivitySync()
        let historyMs = historyStarted.duration(to: .now) / .milliseconds(1)
        let elapsedMs = started.duration(to: .now) / .milliseconds(1)
        logger.notice("host preparation completed host=\(self.hostID.uuidString, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) metadataMs=\(metadataMs, privacy: .public) historyMs=\(historyMs, privacy: .public)")
    }

    /// The live mapping this model actually reads, so migrated timelines can be
    /// checked against the running model rather than only against the file.
    func conversationID(forThreadID threadID: String) async -> UUID? {
        await sessionIndex.conversationID(for: threadID)
    }

    private func presentedChanged(_ presented: Bool, effects: [TargetLifecycle.Effect]) {
        publishDirectoryVisibility(presented)
        feedbackVisibilityGeneration += 1
        reconcileObservation()
        if presented {
            warmConversationsIfIdle()
            reportConnectionStateOnShow()
            run(effects)
        } else {
            fileOpener.leaveScreen()
            ownedTasks.cancel(.warmConversations)
            drafts.requestFlush()
            speech.cancel()
        }
        notifyActiveSessionChange()
    }

    private func publishDirectoryVisibility(_ visible: Bool) {
        directories.setVisible(visible, owner: directoryVisibilityOwner)
    }

    /// Speech output and dictation share one device-wide audio route, so only the
    /// host on screen owns it: a hidden gateway's reply must not talk over the
    /// visible conversation, and a retired one must not speak at all.
    var ownsAudioRoute: Bool { lifecycle.presentation.key && isVisible && acceptsWork }

    func speakIfOwningAudio(_ text: String) {
        guard ownsAudioRoute else { return }
        speech.enqueue(text)
    }

    func applyHostRename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        hostDisplayName = trimmed.isEmpty ? host.connectionSummary : trimmed
    }

    func handleScenePhaseActive() async {
        guard acceptsWork else { return }
        logger.notice("scenePhase active before state update: \(self.liveActivityDebugSummary(), privacy: .public)")
        let effects = lifecycle.handle(.appPhase(.active))
        fileImports.resumeWaiting()
        await gateway.resumeLivenessChecks()
        reconcileObservation()
        for screen in presentingScreens { screen.dictation.refreshRecoverable() }
        await perform(effects)
        if lifecycle.foreground == .deferred {
            logger.notice("scenePhase active deferred gateway refresh for hidden idle context")
        }
    }

    var ownsActiveVoiceCall: Bool {
        realtimeVoice.isActive(for: target)
    }

    private func refreshGatewayAfterForeground(generation: Int) async {
        // Everything below suspends. `isLive` is what keeps a foreground pass
        // that finished after the app was backgrounded (or after this host was
        // removed) from restarting prefetching, polling and transcript refreshes.
        let isLive = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.lifecycle.isCurrent(generation)
        }
        guard isLive() else { return }
        eventPump.startIfNeeded()
        scheduleRouteMove()
        // Folder discovery has no dependency on restoring an existing chat.
        // Keep it structured and generation-scoped, but let both make progress.
        async let directoryRefresh: Void = refreshForegroundDirectory(generation: generation)
        // Discover active turns before the transcript refreshes below depend on them.
        await fetchActiveTurnsOnce()
        guard isLive() else { return }
        await metadataService.syncInBackground()
        await refreshActiveConversationAfterDisconnectIfNeeded()
        guard isLive() else { return }
        await refreshTranscriptOnForegroundIfNeeded()
        logger.notice("scenePhase active completed: \(self.liveActivityDebugSummary(), privacy: .public)")
        await directoryRefresh
    }

    private func refreshForegroundDirectory(generation: Int) async {
        if isVisible { await directories.triggerForegroundRefresh() }
        guard !Task.isCancelled, lifecycle.isCurrent(generation) else { return }
        for screen in screens { screen.adoptRemoteHomeAsWorkingDirectoryIfUnset() }
    }

    // MARK: - Screens

    func makeScreen(newChat: UUID) -> ChatScreenModel {
        let screen = ChatScreenModel(target: self, newChat: newChat)
        registeredScreens.removeAll { $0.screen == nil }
        registeredScreens.append(WeakScreen(screen: screen))
        synchronizeHeaderProtection()
        screen.resumeStagedUploads()
        return screen
    }

    func releaseScreen(_ screen: ChatScreenModel) {
        registeredScreens.removeAll { $0.screen == nil || $0.screen === screen }
        synchronizeHeaderProtection()
    }

    var screens: [ChatScreenModel] { registeredScreens.compactMap(\.screen) }

    var presentingScreens: [ChatScreenModel] {
        let presenting = screens.filter { $0.presentation.presented }
        return presenting.filter { $0.presentation.key } + presenting.filter { !$0.presentation.key }
    }

    /// The key window's screen, else any presenting one: it owns the audio route,
    /// the voice call and the haptic capture that has no originating screen.
    private var primaryScreen: ChatScreenModel? { presentingScreens.first ?? screens.first }

    private func screenShowing(_ threadID: String) -> ChatScreenModel? {
        presentingScreens.first { $0.activeSessionID == threadID } ?? screens.first { $0.activeSessionID == threadID }
    }

    private func isShown(_ threadID: String) -> Bool {
        screens.contains { $0.activeSessionID == threadID }
    }

    private func isPresenting(_ threadID: String) -> Bool {
        presentingScreens.contains { $0.activeSessionID == threadID }
    }

    private var shownThreadIDs: Set<String> { Set(screens.compactMap(\.activeSessionID)) }

    private var aggregatePresentation: TargetPresentation {
        let presenting = presentingScreens
        return TargetPresentation(presented: !presenting.isEmpty, key: presenting.contains { $0.presentation.key },
                                  drawerOpen: screens.contains { $0.presentation.drawerOpen })
    }

    /// The workspace shows exactly one model per window; the rest keep their
    /// connections, drafts and running turns without publishing device-wide state.
    func screenPresentationChanged() {
        guard acceptsWork else { return }
        let next = aggregatePresentation
        guard lifecycle.presentation != next else { return }
        let previous = lifecycle.presentation
        let effects = lifecycle.handle(.presentation(next))
        if next.presented != previous.presented { presentedChanged(next.presented, effects: effects) } else { reconcileObservation() }
        if next.drawerOpen != previous.drawerOpen { for screen in screens { screen.publishSeenCompletion() } }
    }

    // MARK: - VoiceCallHost

    private func voiceScreen() throws -> ChatScreenModel {
        guard let primaryScreen else {
            throw VoiceCallUnavailable(message: "Open a window for this host to continue the voice call.")
        }
        return primaryScreen
    }

    func prepareRealtimeVoiceConversation() async throws -> RealtimeVoiceConversationContext {
        try await voiceScreen().prepareRealtimeVoiceConversation()
    }

    func refreshRealtimeVoiceConversation(
        _ context: RealtimeVoiceConversationContext, using voiceGateway: GatewayClient
    ) async throws -> RealtimeVoiceConversationContext {
        try await voiceScreen().refreshRealtimeVoiceConversation(context, using: voiceGateway)
    }

    func readIncomingVoiceSettings(_ context: RealtimeVoiceConversationContext,
                                   using voiceGateway: GatewayClient,
                                   ownsCall: @escaping @MainActor () -> Bool,
                                   readThread: @escaping @Sendable (String) async throws -> CodexAppServerV2.ThreadReadResponse)
        async -> VoiceIncomingSettingsRead {
        guard let primaryScreen else { return VoiceIncomingSettingsRead(context: context, readModelAndEffort: false, readFastMode: false) }
        return await primaryScreen.readIncomingVoiceSettings(context, using: voiceGateway, ownsCall: ownsCall, readThread: readThread)
    }

    func discardProvisionalRealtimeVoiceConversation(threadID: String?) async {
        await primaryScreen?.discardProvisionalRealtimeVoiceConversation(threadID: threadID)
    }

    func setVoiceModeActive(_ active: Bool) {
        guard isVoiceModeActive != active else { return }
        VoiceModeDiagnostics.log("voice mode model active=\(active) appBackground=\(isInBackground)")
        if active { ownedTasks.cancel(.warmConversations) }
        handleLifecycle(.voiceCall(active))
    }

    func handleScenePhaseInactive() async {
        let effects = lifecycle.handle(.appPhase(.inactive))
        reconcileObservation()
        await perform(effects)
    }

    func handleScenePhaseBackground() async {
        fileOpener.cancelDownload()
        drafts.requestFlush()
        let effects = lifecycle.handle(.appPhase(.background))
        ownedTasks.cancel(.routeMove)
        await gateway.suspendLivenessChecks()
        reconcileObservation()
        for screen in screens {
            screen.historyEdges.cancelReads()
            screen.historyOpenSignpost.abandon(.cancelled)
        }
        connectionState = nil
        await AppPerformanceDiagnostics.shared.clearHistory()
        await AppPerformanceDiagnostics.shared.clearConnection()
        logger.notice("scenePhase background before branch: \(self.liveActivityDebugSummary(), privacy: .public)")
        await perform(effects)
        logger.notice("scenePhase background completed: \(self.liveActivityDebugSummary(), privacy: .public)")
    }

    private func handleLifecycle(_ event: TargetLifecycle.Event) {
        run(lifecycle.handle(event))
    }

    private func run(_ effects: [TargetLifecycle.Effect]) {
        guard !effects.isEmpty else { return }
        ownedTasks.start(.lifecycle) { [weak self] in await self?.perform(effects) }
    }

    /// Effects are computed before their awaits, so each one that depends on the
    /// scene phase or the background hold first checks the reducer still wants it.
    private func perform(_ effects: [TargetLifecycle.Effect]) async {
        for effect in effects {
            guard !Task.isCancelled else { return }
            switch effect {
            case .startLoops:
                startHistoryAutoRefreshIfNeeded()
                scheduleRouteMove()
            case .stopLoops:
                guard !lifecycle.isSceneLive else { continue }
                stopHistoryAutoRefresh()
                directories.suspendRefreshLoop()
            case .refreshForeground(let generation):
                await refreshGatewayAfterForeground(generation: generation)
            case .holdAssertion:
                guard lifecycle.hold == .assertion else { continue }
                backgroundExecution.hold(named: "RemoteCoder.BackgroundGrace") { [weak self] in self?.handleLifecycle(.graceExpired) }
            case .beginGrace:
                guard lifecycle.hold == .grace else { continue }
                logger.notice("background grace starting 25s timer")
                backgroundExecution.holdWithGrace(named: "RemoteCoder.BackgroundGrace", for: .seconds(25)) { [weak self] in
                    self?.handleLifecycle(.graceExpired)
                }
            case .endGrace:
                guard lifecycle.hold != .assertion, lifecycle.hold != .grace else { continue }
                backgroundExecution.release()
            case .disconnect:
                guard lifecycle.hold == .disconnected else { continue }
                await disconnectForBackground()
            case .syncLiveActivity:
                scheduleLiveActivitySync()
            case .flush:
                await flushPersistentState()
            }
        }
    }

    enum TerminationDraftSave {
        case live
        case retirement(Task<Bool, Never>)
        case failedRetirement
    }

    func beginTermination(draftSave: TerminationDraftSave) {
        guard terminationTask == nil else { return }
        let retiring = retirementTask
        drafts.quiesce()
        voice.beginQuiescing()
        _ = lifecycle.handle(.quiesce)
        ownedTasks.quiesce()
        dispatcher.quiesce()
        conversationList.quiesce()
        let shown = screens
        let running = preparation.quiesce() + questions.quiesce() + eventPump.stop()
            + observation.quiesce() + fileImports.quiesce()
        for screen in shown { screen.beginQuiescing() }
        backgroundExecution.release()
        directories.suspendRefreshLoop()
        speech.cancel()
        pendingTerminationOperation = "Gateway and admitted work"
        terminationTask = Task { [self] in
            defer { pendingTerminationOperation = nil }
            await gateway.disconnect()
            await retiring?.value
            for task in running { await task.value }
            await observation.finishQuiescing()
            pendingTerminationOperation = "Host tasks"
            await ownedTasks.drain()
            pendingTerminationOperation = "Turn dispatch"
            await dispatcher.drain()
            pendingTerminationOperation = "Question commands"
            await questions.drain()
            pendingTerminationOperation = "Conversation marks"
            await conversationList.drain()
            var failures: [String] = []
            pendingTerminationOperation = "Dictation recording"
            do { try await voice.quiesceForTermination() }
            catch { failures.append("Dictation recording: " + error.localizedDescription) }
            for screen in shown {
                if let failure = await screen.finishQuiescing() { failures.append("Dictation recording: " + failure) }
            }
            pendingTerminationOperation = "Pending sends"
            await drafts.drainSubmissions()
            pendingTerminationOperation = "Drafts"
            let draftsSaved: Bool
            switch draftSave {
            case .live: draftsSaved = await drafts.flush()
            case .retirement(let task): draftsSaved = await task.value
            case .failedRetirement: draftsSaved = false
            }
            if !draftsSaved { failures.append("Drafts: " + (drafts.errorMessage ?? "Save failed")) }
            pendingTerminationOperation = "Conversation checkpoints"
            let checkpoints = await conversations.flush()
            failures += checkpoints.map { "Conversation checkpoint \($0.conversationID): \($0.reason)" }
            pendingTerminationOperation = "Conversation marks"
            if !(await conversationList.flushMarks()) { failures.append("Conversation marks: Save failed") }
            pendingTerminationOperation = "Voice history"
            if !(await voiceHistoryStore.flush()) { failures.append("Voice history: Save failed") }
            var reported: Set<String> = []
            return failures.filter { reported.insert($0).inserted }.map { hostDisplayName + ": " + $0 }
        }
    }

    func flushForTermination() async -> [String] {
        beginTermination(draftSave: .live)
        return await terminationTask?.value ?? []
    }

    func resumeAfterTermination() {
        terminationTask = nil
        guard lifecycle.phase == .quiescing else { return }
        _ = lifecycle.handle(.resume)
        ownedTasks.resume()
        dispatcher.resume()
        drafts.resume()
        voice.resumeAfterTermination()
        observation.resume()
        questions.resume()
        conversationList.resume()
        for screen in screens { screen.resumeAfterTermination() }
    }

    private func flushPersistentState() async {
        _ = await drafts.flush()
        await conversations.flush()
        await conversationList.flushMarks()
        await voiceHistoryStore.flush()
    }

    /// The synchronous half of retirement, and the fence the whole design rests
    /// on: it must complete before the workspace removes this model, so no
    /// suspended work can resume, restart polling, send a turn or publish
    /// device-wide state into the replacement that takes this host's id.
    ///
    /// This also replaces the old `handleActiveHostChange()`: a model is never
    /// rebound to another address, so the page reads, warm ledger and visible-turn
    /// bookkeeping that used to be reset on a host switch are released here.
    func beginRetirement() {
        guard isRetired == false else { return }
        conversationList.retireHeaderReads()
        conversationList.quiesce()
        let separatelyOwned = [questions.stop()].compactMap { $0 }
            + screens.flatMap { $0.retire() }
        for task in separatelyOwned { task.cancel() }
        ownedTasks.quiesce()
        let preferenceExchange = hostServices.preferenceExchange.retire()
        let running = preparation.retire() + dispatcher.cancelAll() + separatelyOwned
            + [preferenceExchange].compactMap { $0 }
        drafts.requestFlush()
        let ownsDiagnosticsState = isVisible
        _ = lifecycle.handle(.retire)
        fileOpener.leaveScreen()
        reconcileObservation()
        renderedMessages.retire()
        for screen in screens {
            screen.pendingSettings.removeAll()
            screen.historyOpenSignpost.abandon(.cancelled)
        }
        speech.cancel()
        publishDirectoryVisibility(false)
        cancelActivityReads()
        conversationWarmer.clear()
        stopHistoryAutoRefresh()
        for screen in screens { screen.cancelResumeConversationLoad() }
        fileImports.beginRetirement()
        turnsChanged(turns.removeAll())
        conversationActivity = ConversationActivity()
        gatewayConnectivity = .disconnected
        eventPump.stop()
        backgroundExecution.release()
        retirementTask = Task {
            await conversationList.finishHeaderRetirement()
            if realtimeVoice.callOwner == target { await realtimeVoice.stop() }
            await voiceHistoryStore.flush()
            // Fail current RPC waiters before joining the tasks that await them.
            await gateway.retire()
            await conversationList.drain()
            await metadataService.retire()
            await fileImports.retire()
            hostServices.registration.retire()
            await directories.retire()
            await hostServices.routes.retire()
            await observation.retire()
            await questions.drain()
            await ownedTasks.drain()
            for task in running { await task.value }
            await drafts.drainSubmissions()
            await conversations.flush()
            await conversationList.flushMarks()
            await historyService.invalidateAll()
            if ownsDiagnosticsState {
                await AppPerformanceDiagnostics.shared.clearHistory()
                await AppPerformanceDiagnostics.shared.clearConnection()
            }
            #if os(iOS)
            await liveActivityService.end()
            #endif
        }
    }

    /// Admission is closed synchronously; completion is shared by every caller.
    @discardableResult
    func retire() async -> Bool {
        beginRetirement()
        await retirementTask?.value
        return await drafts.retire()
    }

    // MARK: - Background + Live Activity

    private func liveActivityDebugSummary() -> String {
        "bg=\(isInBackground) sticky=\(lifecycle.backgroundSticky) activeTaskCount=\(turns.liveActivityTaskCount) jobs=\(turns.jobs.count) activeTurns=\(turns.trackedThreadIDs.count) pendingRefresh=\(transcriptRecovery.markCount)"
    }

    #if os(iOS)
    private func scheduleLiveActivitySync() {
        guard acceptsWork else { return }
        guard gatewayPolicy.registersDevice else { return }
        let now = Date.now
        let activeTaskCount = turns.liveActivityTaskCount

        // Keep the Live Activity alive once we've backgrounded at least once during an active task.
        let requestsActivity = lifecycle.app != .active || lifecycle.backgroundSticky

        logger.notice(
            "scheduleLiveActivitySync requested requestsActivity=\(requestsActivity, privacy: .public) bg=\(self.isInBackground, privacy: .public) sticky=\(self.lifecycle.backgroundSticky, privacy: .public) activeTaskCount=\(activeTaskCount, privacy: .public) epochSeconds=\(now.timeIntervalSince1970, privacy: .public) summary=\(self.liveActivityDebugSummary(), privacy: .public)"
        )
        let registration = hostServices.registration
        ownedTasks.start(.liveActivitySync) { [self] in
            await liveActivityService.sync(
                requestsActivity: requestsActivity,
                now: now,
                onPushTokenUpdate: { @Sendable token in
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { return }
                    await registration.update(liveActivityToken: trimmed)
                },
                onEnded: {
                    await registration.update(liveActivityToken: nil)
                }
            )
        }
    }
    #endif

    private func disconnectForBackground() async {
        logger.notice("disconnectForBackground start: \(self.liveActivityDebugSummary(), privacy: .public)")
        eventPump.stop()
        ownedTasks.cancel(.routeMove)
        cancelActivityReads()
        conversationList.suspendMarksSync()
        gatewayConnectivity = .disconnected
        // Clear our local guardrail immediately so reconnects can resume via the background listener.
        recoverDispatchedTurnsAfterConnectionLoss()
        turns.endAllDispatched()
        backgroundExecution.release()
        await gateway.disconnect()
        logger.notice("disconnectForBackground completed")
    }

    func startHistoryAutoRefreshIfNeeded() {
        guard acceptsWork, isSceneActive, isHistoryDrawerOpen, !ownedTasks.isRunning(.historyAutoRefresh) else { return }

        ownedTasks.start(.historyAutoRefresh) { [weak self] in
            while !Task.isCancelled {
                guard let self, self.acceptsWork, self.isSceneActive, self.isHistoryDrawerOpen else { return }
                await self.conversationList.refreshIfStale()
                guard !Task.isCancelled, self.acceptsWork, self.isSceneActive, self.isHistoryDrawerOpen else { return }
                self.warmConversationsIfIdle()
                do { try await Task.sleep(for: self.conversationList.automaticRefreshDelay()) }
                catch { return }
            }
        }
    }

    // MARK: - Conversation warming

    /// Prefetches the opening tails of every unsettled conversation in rank order
    /// at background priority and queues their HTML visuals; the top two also get
    /// a session, rendered Markdown and agent lists, so opening one paints from cache.
    func warmConversationsIfIdle() {
        guard !ownedTasks.isRunning(.warmConversations), shouldWarmConversations() else { return }
        let unsettled = unsettledConversationsByRank()
        let top = unsettled.prefix(2).map(\.id).filter(recentConversations.admitsWarmed)
        let hot = top.filter { turns.turn(forThread: $0) == nil }
        let candidates = unsettled.filter(conversationWarmer.needsWarm)
        let agentCandidates = top.filter { recentConversations.agents(threadID: $0) == nil }
        guard !candidates.isEmpty || !agentCandidates.isEmpty else { return }
        ownedTasks.startBackground(.warmConversations) { [weak self] in
            await self?.conversationWarmer.warm(Array(candidates), hot: Set(hot), agentThreadIDs: agentCandidates)
        }
    }

    private func unsettledConversationsByRank() -> [ConversationHeader] {
        let marks = conversationList.marks
        let activity = historyActivityStates
        let questionAskTimes = questionAskTimesByThreadID
        let waitingSince = waitingSinceByThreadID(in: activity)
        let settlementEdits = conversationList.settlementEdits
        let now = Int64(Date.now.timeIntervalSince1970)
        return conversationList.threads.compactMap { thread -> (thread: ConversationHeader, rank: ConversationDrawerRank)? in
            guard !thread.isDelegatedAgent, !isShown(thread.id) else { return nil }
            let rank = ConversationDrawerRank(thread, activity: activity[thread.id],
                questionAskTimes: questionAskTimes[thread.id] ?? [], waitingSince: waitingSince[thread.id],
                marks: marks, settlementEdit: settlementEdits[thread.id] ?? 0, at: now)
            guard !rank.isSettled, rank.isLive || marks.purpose(of: thread.id) != .probe else { return nil }
            return (thread, rank)
        }
        .sorted { ($0.rank.tier.rawValue, $1.rank.recency) < ($1.rank.tier.rawValue, $0.rank.recency) }
        .map(\.thread)
    }

    var mayWarm: Bool { shouldWarmConversations() }

    var presentedConversationIDs: Set<UUID> { Set(screens.map(\.currentConversationID)) }

    func selectionIsCurrent(revision: UInt64, threadID: String) -> Bool {
        screenShowing(threadID)?.selectionIsCurrent(revision: revision, threadID: threadID) ?? false
    }

    func refreshAgents(threadID: String) async {
        let agents = agentsModel(threadID: threadID)
        recentConversations.recordWarmed(agents)
        await agents.refreshIfNeeded()
    }

    func didWarm(_ snapshot: ConversationSnapshot, session: ConversationSession) {
        recentConversations.recordWarmed(snapshot, session: session)
        renderedMessages.ensureRendered(snapshot.messages)
    }

    var htmlVisualPreparationContext: HTMLVisualPreparationContext? {
        presentingScreens.first?.htmlVisualPreparation.layoutContext.preparationContext
    }

    func prepareHTMLVisuals(_ references: [HTMLVisualReference]) async -> HTMLVisualPreparationOutcome {
        guard let screen = presentingScreens.first else { return .interrupted }
        return await screen.htmlVisualPreparation.prepareInBackground(references, documents: screen.htmlVisualDocuments)
    }

    /// Kept at the owning model boundary and rechecked after each suspension.
    func shouldWarmConversations(policy: AppEnergyPolicy = .current) -> Bool {
        acceptsWork && isVisible && isSceneActive && !isVoiceModeActive && !policy.conservesEnergy
            && presentingScreens.allSatisfy { $0.loadingTranscriptID == nil && $0.historyEdges.isIdle && $0.historyEdges.allowsPrefetch }
    }

    func handleEnergyPolicyChanged(_ policy: AppEnergyPolicy) {
        if policy.conservesEnergy { ownedTasks.cancel(.warmConversations) }
        else { warmConversationsIfIdle() }
    }

    func retainPresentedRenders() {
        renderedMessages.retainPresented(Set(presentingScreens.flatMap(\.renderWindowIDs)))
    }

    func releaseReusableCaches() {
        ownedTasks.cancel(.warmConversations)
        hostServices.imagePreviews.releaseReusableCaches()
        recentConversations.removeAll(keeping: shownThreadIDs)
        renderedMessages.trim(keeping: Set(presentingScreens.flatMap(\.renderWindowIDs)))
    }

    func cancelConversationWarming() {
        ownedTasks.cancel(.warmConversations)
    }

    private func stopHistoryAutoRefresh() {
        ownedTasks.cancel(.warmConversations)
        ownedTasks.cancel(.historyAutoRefresh)
    }

    // MARK: - Gateway Route

    private func scheduleRouteMove() {
        guard let route = gatewayRoute, route != .lan, !isInBackground else { return }
        if routeMoveRunning, routeMoveLoop?.isCancelled == false {
            routeMoveRequested = true
            return
        }
        routeMoveLoop = ownedTasks.start(.routeMove) { [weak self] in
            while !Task.isCancelled, let delay = await self?.moveToPreferredRoute() {
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func moveToPreferredRoute() async -> Duration? {
        routeMoveRequested = false
        routeMoveRunning = true
        defer { if !Task.isCancelled { routeMoveRunning = false } }
        let move = routeMoveAllowed
            ? await gateway.moveToPreferredRoute { [weak self] in self?.routeMoveAllowed ?? false } : .settled
        guard !Task.isCancelled, let route = gatewayRoute, route != .lan else { return nil }
        if routeMoveRequested { return .zero }
        return move == .deferred ? Self.deferredRouteMoveDelay : Self.routeMoveInterval
    }

    private var routeMoveAllowed: Bool {
        lifecycle.needsGatewayLoops && !isInBackground && !realtimeVoice.isActive
            && !screens.contains { turns.isBusy(conversationID: $0.currentConversationID, threadID: $0.activeSessionID) }
    }

    // MARK: - Active Turns (Daemon Snapshot)

    private var allowsActivityReads: Bool { lifecycle.allowsActivityReads }

    func startActivityRefresh() {
        guard allowsActivityReads else { return }
        activityReadRequested = true
        guard !ownedTasks.isRunning(.inventoryRefresh) else { return }
        ownedTasks.start(.inventoryRefresh) { [weak self] in
            while let self, self.activityReadRequested, !Task.isCancelled {
                self.activityReadRequested = false
                await self.fetchAndApplyActiveTurns()
            }
        }
    }

    private func fetchActiveTurnsOnce() async {
        startActivityRefresh()
        await ownedTasks.value(.inventoryRefresh)
    }

    private func fetchAndApplyActiveTurns() async {
        guard !Task.isCancelled else { return }
        let requestedAt = Date.now
        do {
            let snapshot = try await gateway.readActiveTurns()
            guard !Task.isCancelled else { return }
            activityReadFailures = 0
            applyActivity(snapshot, observedAt: requestedAt)
        } catch {
            guard !Task.isCancelled else { return }
            activityReadFailed(error)
        }
    }

    private func cancelActivityReads() {
        ownedTasks.cancel(.inventoryRefresh)
        activityReadRequested = false
        ownedTasks.cancel(.scheduledActivityRead)
        scheduledActivityDue = nil
    }

    private func activityReadFailed(_ error: Error) {
        guard !(error is CancellationError) else { return }
        activityReadFailures += 1
        scheduleActivityRead(after: Self.retryDelay(afterFailures: activityReadFailures))
    }

    func applyActivity(_ snapshot: CodexGatewayDaemon.ActiveTurnsResponse, observedAt: Date) {
        guard acceptsWork else { return }
        if let known = activitySnapshotVersion, known.epoch == snapshot.epoch, snapshot.revision < known.revision { return }
        activitySnapshotVersion = (snapshot.epoch, snapshot.revision)
        reconcileWithDaemonActiveTurns(snapshot, observedAt: observedAt)
    }

    private func scheduleActivityRead(after delay: TimeInterval) {
        guard allowsActivityReads else { return }
        let due = ContinuousClock.now + .seconds(delay)
        if let scheduledDue = scheduledActivityDue, due >= scheduledDue { return }
        scheduledActivityDue = due
        ownedTasks.start(.scheduledActivityRead) { [weak self] in
            try? await Task.sleep(until: due)
            guard let self, !Task.isCancelled else { return }
            self.scheduledActivityDue = nil
            self.startActivityRefresh()
        }
    }

    private static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(TimeInterval(1 << min(failures, 5)), 30)
    }

    func handleHistoryDrawerVisibilityChanged(_ isOpen: Bool) async {
        guard isOpen else { stopHistoryAutoRefresh(); return }
        await fetchActiveTurnsOnce()
        guard isHistoryDrawerOpen, isSceneActive, acceptsWork, !Task.isCancelled else { return }
        refreshQuestionScopes()
        if historyBusySessionIDs.isEmpty {
            await conversationList.refreshIfStale()
        } else {
            await conversationList.refresh(reason: "history-open-active-turns")
        }
        startHistoryAutoRefreshIfNeeded()
    }

    /// Applies the daemon's authoritative active-turn snapshot. Internal because
    /// `applyActivity` and the busy-state regression tests are its only callers.
    func reconcileWithDaemonActiveTurns(_ reported: CodexGatewayDaemon.ActiveTurnsResponse, observedAt now: Date) {
        let outcome = turns.apply(reported, observedAt: now)
        turnsChanged(outcome.change)
        let snapshot = outcome.snapshot
        let activity = ConversationActivity(snapshot: snapshot)
        if conversationActivity != activity { conversationActivity = activity }
        turnStops.reopen(
            stillRunning: Set(snapshot.activeTurns.map { RunningTurn(threadID: $0.threadId, turnID: $0.turnId) }),
            requestedAt: now
        )

        // If the daemon reports an active turn for the currently open session, try to attach so
        // steering + live timelines work even if we missed earlier notifications.
        for entry in snapshot.activeTurns {
            guard isShown(entry.threadId), let active = turns.turn(forThread: entry.threadId) else { continue }
            synchronizeConversationActivity()
            if AgentProvider.provider(forThreadID: entry.threadId) == .claude {
                if let startedAtSequence = entry.startedAtSequence {
                    replayActiveClaudeTurnNotificationsIfNeeded(active, afterSequence: startedAtSequence - 1, epoch: snapshot.epoch)
                }
            } else { observation.discoveredActiveThread(entry.threadId) }
        }

        // The registry sweeps every locally busy session, not just the ones with a
        // tracked active turn: a job that lost its turn (missed completion, a stream
        // that finished after a newer turn replaced the tracked one) would otherwise
        // keep the history row on "Working" until relaunch.
        for sessionDecision in outcome.decisions {
            let threadID = sessionDecision.threadID
            switch sessionDecision.decision {
            case .keepActive, .unknown:
                continue
            case .pending:
                scheduleActivityRead(after: TurnRegistry.confirmationWindow)
            case .retire(let jobIDs, let clearsActiveTurn):
                logger.notice(
                    "retiring gateway jobs confirmed inactive session=\(threadID, privacy: .public) jobs=\(jobIDs.sorted().joined(separator: ","), privacy: .public) clearsActiveTurn=\(clearsActiveTurn, privacy: .public)"
                )
                if isShown(threadID) { reconcileTranscriptAfterRetirement(sessionID: threadID) }
            }
        }

        synchronizeConversationActivity()
    }

    private func replayActiveClaudeTurnNotificationsIfNeeded(_ active: TrackedTurn, afterSequence: UInt64, epoch: String) {
        guard !isDispatchedTurnVisible(active.jobID) else { return }
        guard turns.claimReplay(jobID: active.jobID) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.eventPump.replayThread(afterSequence: afterSequence, epoch: epoch, threadID: active.threadID, limit: 2_000)
            } catch {
                self.turns.releaseReplay(jobID: active.jobID)
                self.logger.notice("Failed to replay active Claude turn: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func replayOpenedClaudeThread(threadID: String, owner: ConversationSession) async {
        do {
            let snapshot = try await gateway.readActiveTurns()
            guard !isRetired, !Task.isCancelled,
                  await conversations.existingSession(threadID: threadID) === owner else { return }
            guard !isRetired, !Task.isCancelled,
                  let turn = snapshot.activeTurns.first(where: { $0.threadId == threadID }),
                  let sequence = turn.startedAtSequence, sequence > 0 else { return }
            try await eventPump.replayThread(afterSequence: sequence - 1, epoch: snapshot.epoch, threadID: threadID, limit: 2_000)
        } catch {
            if !Task.isCancelled {
                logger.notice("Failed to replay opened Claude turn: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Gateway Notifications

    var acceptsConnectionReports: Bool { acceptsWork && !isInBackground }
    var acceptsGatewayEvents: Bool { acceptsWork }

    private var acceptsCurrentGatewayDelivery: Bool {
        acceptsWork && !Task.isCancelled && (GatewayEventPump.delivery?.isCurrent ?? true)
    }

    func gatewayActivityRefreshRequested() {
        startActivityRefresh()
    }

    func gatewayThreadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {
        observation.threadClosed(threadID, receipt: receipt)
    }

    func gatewayConnectionChanged(_ link: GatewayEventPump.Link, connection: UUID?) async {
        if let connection {
            reconcileObservation(); observation.connected(connection)
            for screen in screens { screen.historyEdges.retryFailed() }
            if conversationList.needsReconnectRefresh {
                ownedTasks.start(.historyRetry) { [weak self] in await self?.conversationList.refresh(reason: "reconnect") }
            }
            hostServices.registration.retry()
            directories.syncFavorites()
            hostServices.preferenceExchange.sync()
            #if os(iOS)
            if gatewayPolicy.registersDevice {
                ownedTasks.start(.liveActivityRead) { [weak self] in
                    guard let self else { return }
                    do {
                        try await liveActivityService.refresh { [gateway] in try await gateway.readLiveActivity() }
                        guard !Task.isCancelled, !isRetired else { return }
                        scheduleLiveActivitySync()
                    } catch {
                        guard !Task.isCancelled else { return }
                        logger.notice("Live Activity snapshot unavailable: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            #endif
            refreshQuestionScopes()
            if codexModels.hasFetched == false { startCodexModelRefresh() }
            ownedTasks.start(.marksSync) { [weak self] in await self?.conversationList.syncMarks() }
            if metadataConnectionID != connection {
                metadataConnectionID = connection
                await metadataService.syncInBackground()
            }
        }
        else {
            markActivityUnavailable()
            if link == .disconnected {
                recoverDispatchedTurnsAfterConnectionLoss()
                observation.disconnected()
                await questions.invalidate()
                questions.forgetCounts()
            }
        }
        await recordConnectionState(link)
    }

    func gatewayConnectivityChanged(_ connectivity: GatewayConnectivity) async {
        guard connectivity != gatewayConnectivity else { return }
        let wasConnected = isGatewayConnected
        gatewayConnectivity = connectivity
        scheduleRouteMove()
        guard isGatewayConnected else {
            if wasConnected { hostServices.automations.connectivityChanged(false) }
            return
        }
        guard !wasConnected else { return }
        hostServices.automations.connectivityChanged(true)
        directories.connectionChanged()
        _ = try? await directories.resolveHomePath()
        await refreshActiveConversationAfterDisconnectIfNeeded()
    }

    func gatewayNetworkPathChanged() {
        scheduleRouteMove()
    }

    private func recordConnectionState(_ state: GatewayEventPump.Link) async {
        connectionState = state
        guard isVisible else { return }
        await AppPerformanceDiagnostics.shared.connectionChanged(state, provider: primaryScreen?.currentAgentProvider == .claude ? .claude : .codex)
    }

    private func reportConnectionStateOnShow() {
        let state = connectionState
        let provider: AppPerformanceDiagnostics.Provider = primaryScreen?.currentAgentProvider == .claude ? .claude : .codex
        Task {
            if let state { await AppPerformanceDiagnostics.shared.connectionChanged(state, provider: provider) }
            else { await AppPerformanceDiagnostics.shared.clearConnection() }
        }
    }

    func reconcile(gap: ReplayProgress.Gap) async {
        guard acceptsWork else { return }
        startActivityRefresh()
        transcriptRecovery.invalidateForegroundRefresh()
        let resident = Set(await conversations.openThreadIDs())
        let affected: Set<String>
        switch gap {
        case .allThreads:
            conversationWarmer.clear()
            await historyService.invalidateAll()
            affected = resident.union(shownThreadIDs)
        case .threads(let threads):
            for threadID in threads {
                conversationWarmer.invalidate(threadID)
                await historyService.invalidate(threadID: threadID)
            }
            affected = resident.intersection(threads).union(shownThreadIDs.intersection(threads))
        }

        let shownAffected = shownThreadIDs.intersection(affected)
        if !shownAffected.isEmpty {
            for sessionID in shownAffected.sorted() { observation.retry(threadID: sessionID) }
            await questions.invalidate()
            refreshQuestionScopes()
        }
        for threadID in affected.sorted() {
            guard acceptsWork, !Task.isCancelled else { return }
            let session = await conversations.session(threadID: threadID)
            let read = await session.beginHistoryRead()
            do {
                let snapshot = try await historyService.refreshTail(threadID: threadID, base: read.base, bypassCache: true)
                guard acceptsWork, !Task.isCancelled else { return }
                if let screen = screenShowing(threadID) ?? primaryScreen {
                    await screen.applyConversationSnapshot(snapshot, read: read, from: session, source: "gap")
                } else {
                    _ = await session.merge(snapshot, read: read)
                }
            } catch {
                logger.notice("Failed to refresh conversation after notification gap thread=\(threadID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !shownThreadIDs.isDisjoint(with: affected) {
            startActivityRefresh()
        }
    }

    /// Applies one routed gateway event to main-actor state. Filtering and
    /// payload decoding already happened off-main in `GatewayNotificationRouting`.
    /// Internal because the notification pump and the busy-state regression
    /// tests are its callers.
    func defersReplay(_ event: RoutedGatewayEvent) -> Bool {
        switch event {
        // Historical settings events are superseded by the current thread read.
        case .settings: true
        case .turnEvent(let turnEvent):
            isShown(turnEvent.threadID) && !turnEvent.threadID.hasPrefix("claude_") && observation.state(of: turnEvent.threadID) != .detached
        default: false
        }
    }

    func apply(gatewayEvent event: RoutedGatewayEvent, replay: Bool = false) async {
        guard acceptsCurrentGatewayDelivery, !(replay && defersReplay(event)) else { return }
        switch event {
        case .activity(let snapshot):
            applyActivity(snapshot, observedAt: .now)
        case .liveActivity(let snapshot):
            #if os(iOS)
            await liveActivityService.receive(snapshot)
            guard !isRetired else { return }
            scheduleLiveActivitySync()
            #endif
        case .warning(let warning):
            gatewayWarning = warning
            logger.error("\(warning.message, privacy: .public)")
        case .settings(let notification, _):
            await metadataService.observeSettings(notification, observedAt: .now)
            guard !isRetired else { return }
            let reportedFastMode = notification.threadSettings.fastModeSelection
            guard screens.allSatisfy({ $0.pendingSettings[notification.threadId] == nil }),
                  let model = modelCatalog.option(id: notification.threadSettings.model, threadID: notification.threadId,
                                          effort: notification.threadSettings.effort?.rawValue, fastMode: reportedFastMode == true) else { return }
            let reasoning = notification.threadSettings.effort.flatMap { ReasoningEffort(rawValue: $0.rawValue) }
                .map(ReasoningSelection.effort) ?? .automatic
            let shown = screenShowing(notification.threadId)
            if let shown {
                shown.pickerSelection.observe(model: model, reasoning: reasoning, reportedFastMode: reportedFastMode)
                shown.refreshReasoningVisibility()
            }
            let voiceSettings = primaryScreen?.voiceConversationSettings
            let voiceState = voiceSettings?.threadId == notification.threadId
                ? voiceSettings?.fastModeState.observing(reportedFastMode)
                : (shown.map { $0.fastModeState.observing(reportedFastMode) }
                    ?? FastModeState.readback(reportedFastMode, remembered: nil))
            if let voiceState {
                realtimeVoice.applyConversationSettings(
                    ConversationSettingsUpdate(threadID: notification.threadId, model: model,
                        reasoning: reasoning, fastModeState: voiceState),
                    hostID: hostID)
            }
        case .threadName(let notification):
            await conversationList.recordThreadName(threadID: notification.threadId, name: notification.threadName)
        case .queueChanged(let threadID):
            dispatcher.reconcileQueue(threadID: threadID)
        case .historyInvalidated(let threadID, let removed, _):
            let service = historyService
            await conversations.invalidate(threadID: threadID)
            conversationWarmer.invalidate(threadID)
            for screen in screens where screen.activeSessionID == threadID {
                screen.historyEdges.cancelReads()
            }
            ownedTasks.start(.historyInvalidation(threadID)) { [weak self] in
                await service.invalidate(threadID: threadID)
                guard let self, self.acceptsWork, !Task.isCancelled else { return }
                if removed {
                    await self.conversationList.forget(threadID)
                    guard self.acceptsWork, !Task.isCancelled else { return }
                    for screen in self.screens where screen.activeSessionID == threadID { screen.startNewConversation() }
                } else {
                    for screen in self.screens where screen.activeSessionID == threadID {
                        guard self.acceptsWork, !Task.isCancelled else { return }
                        await screen.openConversation(threadID: threadID).value
                    }
                }
            }
        case .archive(let threadID, true, _):
            await conversationList.forget(threadID)
            guard acceptsCurrentGatewayDelivery else { return }
            for screen in screens where screen.activeSessionID == threadID { screen.startNewConversation() }
        case .archive(_, false, _):
            Task { @MainActor [weak self] in
                guard let self, self.acceptsWork else { return }
                await self.conversationList.refresh(reason: "thread-unarchived")
            }
        case .marks(let delta):
            conversationList.receiveMarks(delta)
        case .favorites(let favorites):
            directories.receiveFavorites(favorites)
        case .preferences(let preferences):
            hostServices.preferenceExchange.receive(preferences)
        case .tokenUsage(let notification, _):
            for screen in screens { screen.recordTokenUsage(notification.tokenUsage, threadID: notification.threadId) }
            await conversations.existingSession(threadID: notification.threadId)?
                .recordTokenUsage(turnID: notification.turnId, usage: notification.tokenUsage)
        case .turnEvent(let turnEvent):
            if turnEvent.isLifecycle {
                if !(await ingestSelectedLifecycle(turnEvent, replay: replay)) {
                    guard acceptsCurrentGatewayDelivery else { return }
                    await conversations.ingest(turnEvent, replay: replay)
                }
                guard acceptsCurrentGatewayDelivery else { return }
                await applyTurnLifecycle(turnEvent, replay: replay)
            } else {
                await conversations.ingest(turnEvent, replay: replay)
            }
        }
    }

    private func ingestSelectedLifecycle(_ event: TurnScopedGatewayEvent, replay: Bool) async -> Bool {
        let address = ConversationAddress(hostID: hostID, threadID: event.threadID)
        guard let screen = screenShowing(address.threadID), screen.executionTarget == address.target else { return false }
        let isCurrent = {
            self.acceptsCurrentGatewayDelivery
                && self.screens.contains { $0 === screen && $0.executionTarget == address.target && $0.activeSessionID == address.threadID }
        }
        let conversationID = await sessionIndex.conversationID(for: address.threadID)
            ?? ChatMessage.deterministicID(for: address.threadID)
        guard isCurrent() else { return false }
        _ = await conversations.session(conversationID: conversationID, threadID: address.threadID)
        guard isCurrent() else { return false }
        await conversations.ingest(event, replay: replay)
        return true
    }

    private func applyTurnLifecycle(_ turnEvent: TurnScopedGatewayEvent, replay: Bool) async {
        guard acceptsCurrentGatewayDelivery else { return }
        applyTurnScopedGatewayEvent(turnEvent, replay: replay, feedback: feedbackForCurrentConversation())
        if case .turnCompleted(let completion) = turnEvent.note.server, !turnEvent.threadID.hasPrefix("claude_"),
           let completedAt = completion.completedAt {
            await conversationList.recordTurnCompletion(threadID: turnEvent.threadID, completedAt: completedAt)
        }
    }

    private func applyTurnScopedGatewayEvent(_ event: TurnScopedGatewayEvent, replay: Bool,
                                            feedback: (HapticEvent) -> Void) {
        let note = event.note
        let method = event.method
        let threadID = event.threadID
        let turnID = event.turnID
        let jobID = event.jobID
        conversationWarmer.changed(threadID)
        // The three sites gated on this stay .debug, which on iOS is memory-only and never
        // reaches the host log copy. item/completed fires per timeline item while a turn
        // streams, and the gateway journal already records every one of these notifications
        // server-side with its full payload.
        let shouldLogNotification = method == "turn/started"
            || method == "turn/completed"
            || method == "item/completed"
        if shouldLogNotification {
            logger.debug(
                "gateway note method=\(method, privacy: .public) thread=\(threadID, privacy: .public) turn=\(turnID, privacy: .public) active=\((self.primaryScreen?.activeSessionID ?? "nil"), privacy: .public) job=\(jobID, privacy: .public) dispatchedVisible=\(self.isDispatchedTurnVisible(jobID)) knownActive=\(self.turns.turn(forThread: threadID) != nil) summary=\(self.primaryScreen?.debugChatStateSummary() ?? "none", privacy: .public)"
            )
        }

        if case .turnCompleted(let completion) = note.server {
            reportTurnFeedback(threadID: threadID, turnID: turnID,
                               outcome: TaskOutcome(status: completion.status?.rawValue ?? "unknown"),
                               replay: replay, feedback: feedback)
        }

        // Ignore late/out-of-order events for turns we already marked completed.
        // Normalize because history uses "turn-1" while live notifications use "1".
        let normalizedTurnID = event.normalizedTurnID
        if turns.hasCompleted(threadID: threadID, turnID: normalizedTurnID) {
            logger.debug(
                "ignoring late gateway event method=\(method, privacy: .public) thread=\(threadID, privacy: .public) turn=\(normalizedTurnID, privacy: .public)"
            )
            return
        }

        if case .agentMessage(let itemID, _, _, .async, let questions) = event.item,
           questions?.isEmpty == false {
            let occurrence = HapticOccurrence(hostID: hostID, kind: .question, id: threadID + "|" + itemID)
            // Consume replay/hidden occurrences too; a later completion must not replay attention.
            if haptics.consume(occurrence), !replay, isPresenting(threadID) { feedback(.warning) }
        }

        if method == "turn/completed" {
            var status: CodexAppServerV2.TurnStatus?
            if case .turnCompleted(let completion) = note.server { status = completion.status }
            finishDispatchedTurn(jobID: jobID, status: status, replay: replay)
            handleGatewayTurnCompleted(
                threadID: threadID,
                turnID: turnID
            )
            return
        }

        if method == "item/completed", !replay,
           case .agentMessage(_, let text, _, _, _) = event.item, text.isEmpty == false {
            turns.recordFinalReply(text, jobID: jobID)
        }

        // Any non-completion lifecycle event is evidence of an active turn.
        if case .adopted(let change) = turns.adopt(threadID: threadID, turnID: turnID) {
            turnsChanged(change)
            synchronizeConversationActivity()
        }
    }

    func reportTurnFeedback(threadID: String, turnID: String, outcome: TaskOutcome,
                            replay: Bool, feedback: (HapticEvent) -> Void) {
        guard outcome != .unknown else { return }
        let occurrence = HapticOccurrence(hostID: hostID, kind: .turn,
                                          id: threadID + "|" + normalizeGatewayTurnID(turnID))
        guard haptics.consume(occurrence), !replay, isPresenting(threadID),
              let event = outcome.haptic else { return }
        feedback(event)
    }

    private func finishDispatchedTurn(jobID: String, status: CodexAppServerV2.TurnStatus?, replay: Bool) {
        guard let turn = turns.finishDispatched(jobID: jobID) else { return }
        guard !replay, status == .completed, let reply = turn.finalReply,
              isVisibleConversation(turn.conversationID, sessionID: turn.threadID) else { return }
        speakIfOwningAudio(reply)
    }

    private func recoverDispatchedTurnsAfterConnectionLoss() {
        let recovering = Set(turns.dispatchedTurns.map(\.threadID)).union(shownThreadIDs)
        for sessionID in recovering {
            guard let turn = turns.turn(forThread: sessionID) else { continue }
            transcriptRecovery.mark(sessionID: turn.threadID, turnID: turn.turnID)
            logger.notice(
                "gateway turn lost connection; scheduling disconnect transcript refresh thread=\(turn.threadID, privacy: .public) turn=\(self.normalizeGatewayTurnID(turn.turnID), privacy: .public)"
            )
            Task { [self] in
                try? await Task.sleep(for: .milliseconds(450))
                await refreshTranscriptAfterDisconnectIfNeeded(sessionID: sessionID)
            }
        }
    }

    func reconcileInputDelivery(threadID: String) async {
        guard acceptsWork else { return }
        await transcriptRecovery.reconcileInputDelivery(sessionID: threadID)
    }

    private func handleGatewayTurnCompleted(
        threadID: String,
        turnID: String
    ) {
        guard let completed = turns.complete(threadID: threadID, turnID: turnID) else {
            logger.debug(
                "ignoring repeated gateway turn completion thread=\(threadID, privacy: .public) turn=\(self.normalizeGatewayTurnID(turnID), privacy: .public)"
            )
            return
        }
        turnsChanged(completed.change)
        dispatcher.turnCompleted(threadID: threadID, turnID: turnID)

        logger.info(
            "gateway turn completed thread=\(completed.threadID, privacy: .public) turn=\(completed.normalizedTurnID, privacy: .public) job=\(completed.jobID, privacy: .public) active=\((self.primaryScreen?.activeSessionID ?? "nil"), privacy: .public) summary=\(self.primaryScreen?.debugChatStateSummary() ?? "none", privacy: .public)"
        )

        synchronizeConversationActivity()

        if isShown(completed.threadID),
           transcriptRecovery.awaitsCompletion(ofNormalizedTurn: completed.normalizedTurnID, sessionID: completed.threadID) {
            Task { [weak self] in
                await self?.refreshTranscriptAfterDisconnectIfNeeded(sessionID: completed.threadID)
            }
        }

        // User-facing alerts come only from broker delivery. Producing another
        // banner here races APNs, delayed pushes and reconnect replay.
    }

    private func normalizeGatewayTurnID(_ raw: String) -> String {
        GatewayNotificationRouting.normalizeTurnID(raw)
    }

    func isVisibleConversation(_ conversationID: UUID, sessionID: String? = nil) -> Bool {
        // A retired model has no visible conversation: its late arrivals must not
        // publish anything, on screen or on the audio route.
        guard acceptsWork else { return false }
        return screens.contains { screen in
            screen.currentConversationID == conversationID && (sessionID == nil || screen.activeSessionID == sessionID)
        }
    }

    private func isDispatchedTurnVisible(_ jobID: String) -> Bool {
        guard let turn = turns.dispatchedTurn(id: jobID) else { return false }
        return isVisibleConversation(turn.conversationID, sessionID: turn.threadID)
    }

    func activeSessionChanged(to threadID: String?) {
        synchronizeHeaderProtection()
        if threadID == nil { reconcileObservation() }
        notifyActiveSessionChange()
    }

    func recordPresented(_ snapshot: ConversationSnapshot, session: ConversationSession) {
        recentConversations.record(snapshot, session: session)
        questions.record(snapshot)
    }

    func recentPresentation(threadID: String) -> RecentConversationCache.Presentation? {
        recentConversations.presentation(threadID: threadID)
    }

    func presentationChanged() {
        reconcileObservation()
    }

    func questionScopesChanged() {
        requestAddedQuestionScopes()
    }

    func markCompletionSeen(threadID: String, completedAt: Int64) {
        conversationList.markSeen(threadID: threadID, completedAt: completedAt)
    }

    /// Let the workspace dismiss a banner when its exact conversation is opened.
    private func notifyActiveSessionChange() {
        guard isVisible else { return }
        onActiveSessionChange?(self)
    }

    func dictationFailed(_ message: String) {
        voiceError = message
    }

    // MARK: - Internals: Gateway Turn

    func threadStarted(_ thread: CodexAppServerV2.Thread, session: ConversationSession, settingsRevision: UInt64,
                       requestedServiceTier: CodexAppServerV2.ServiceTierOverride?) async {
        if let owner = screens.first(where: { $0.selectedConversation === session }) {
            if owner.activeSessionID == nil { owner.setActiveSessionID(thread.id) }
            if requestedServiceTier == nil {
                owner.acceptThreadTierReadback(thread.extra, threadID: thread.id, selectionRevision: settingsRevision)
            }
        }
        await conversationList.record(ConversationHeader.prepare(thread))
    }

    /// Retires exactly one gateway job: used by the stale-steer fallback and poll
    /// reconciliation, neither of which may erase a
    /// *different* turn's runtime authority. The active-turn entry is cleared
    /// only while it still is this job, and the turn is tombstoned so a replayed
    /// or late notification cannot re-register what we just retired.
    func retireGatewayJob(
        threadID: String,
        turnID: String?,
        jobID: String
    ) {
        turnsChanged(turns.retire(jobID: jobID, threadID: threadID, turnID: turnID))
        // Clears the busy row and stops any timeline segment showing "running".
        // Draining the queued-message backlog stays with the callers that own a
        // dispatch point, so retirement cannot race a caller's own send.
        synchronizeConversationActivity()
    }

    // MARK: - Task Completion Notifications

    /// A read-only preparation step: the workspace owns notification and launch
    /// navigation and checks that nothing superseded it before committing the
    /// returned exact thread.
    func conversationHeader(threadID: String) async throws -> ConversationHeader {
        if let known = await conversationList.knownThread(id: threadID) { return known }
        return try await ConversationHeader.prepare(gateway.readThread(threadID: threadID, includeTurns: false).thread)
    }

    // MARK: - Disconnect Recovery

    func reconciliationKey(sessionID: String) -> TranscriptRecovery.ReconciliationKey {
        TranscriptRecovery.ReconciliationKey(
            sessionID: sessionID, identity: (screenShowing(sessionID) ?? primaryScreen)?.transcriptIdentity ?? "", scenePhase: lifecycle.generation,
            observation: conversationWarmer.observation(threadID: sessionID, revision: 0))
    }

    func applyReconciledHistory(sessionID: String, source: String) async throws {
        #if os(macOS) && RC_PERF_HARNESS
        if switchFixtures[sessionID] != nil { return }
        #endif
        guard let shown = screenShowing(sessionID) ?? primaryScreen else { throw CancellationError() }
        let identity = shown.transcriptIdentity
        let session = await conversations.session(threadID: sessionID)
        let read = await session.beginHistoryRead()
        let snapshot = try await historyService.refreshTail(threadID: sessionID, base: read.base, bypassCache: true)
        try Task.checkCancellation()
        guard shown.transcriptIdentity == identity, acceptsWork else { throw CancellationError() }
        await shown.applyConversationSnapshot(snapshot, read: read, from: session, source: source)
    }

    func applyInputDeliveryEvidence(sessionID: String) async throws {
        let session = await conversations.session(threadID: sessionID)
        let header = try await historyService.readHeader(threadID: sessionID)
        let snapshot = try await historyService.openTail(header: header, base: nil,
            priority: .reconciliation, bypassCache: true)
        try Task.checkCancellation()
        guard acceptsWork else { throw CancellationError() }
        await session.reconcileDeliveryEvidence(snapshot)
    }

    func trackedTurnID(forThread threadID: String) -> String? {
        turns.turn(forThread: threadID)?.turnID
    }

    private func refreshActiveConversationAfterDisconnectIfNeeded() async {
        for sessionID in shownThreadIDs.sorted() {
            await refreshTranscriptAfterDisconnectIfNeeded(sessionID: sessionID)
        }
    }

    /// Transcript reconciliation on every foreground return, for remote changes made while the app
    /// was backgrounded. It shares one read with a reconnect refresh in the same foreground pass, and
    /// reuses it until a notification, gap or transcript switch ends that read's coverage.
    private func refreshTranscriptOnForegroundIfNeeded() async {
        for screen in presentingScreens {
            guard screen.historyEdges.isIdle, screen.loadingTranscriptID == nil, let sessionID = screen.activeSessionID else { continue }
            await transcriptRecovery.refreshOnForeground(sessionID: sessionID) { screen.activeSessionID == sessionID }
        }
    }

    private func refreshTranscriptAfterDisconnectIfNeeded(sessionID: String) async {
        guard screens.allSatisfy({ $0.loadingTranscriptID == nil }) else { return }
        await transcriptRecovery.recoverAfterDisconnect(sessionID: sessionID)
    }

    private func reconcileTranscriptAfterRetirement(sessionID: String) {
        transcriptRecovery.forget(sessionID: sessionID)
        Task { [weak self] in _ = await self?.transcriptRecovery.reconcile(sessionID: sessionID, source: "retire") }
    }

    // MARK: - Helpers

    func refreshCodexModels() async {
        startCodexModelRefresh()
        await ownedTasks.value(.codexModelRefresh)
    }

    func restoreCachedCodexModels() async {
        await ownedTasks.value(.codexModelCacheLoad)
    }

    private func startCodexModelCacheLoad() {
        let codexModels = codexModels
        ownedTasks.start(.codexModelCacheLoad) { [weak self] in
            await codexModels.restoreCachedCatalog()
            guard !Task.isCancelled, let self, !self.isRetired else { return }
            for screen in self.screens { screen.applyModelCatalog(for: .codex, visibilityBefore: self.codexModelVisibility) }
        }
    }

    private func startCodexModelRefresh() {
        let codexModels = codexModels
        guard acceptsWork, !ownedTasks.isRunning(.codexModelRefresh) else { return }
        ownedTasks.start(.codexModelRefresh) { [weak self] in
            await self?.restoreCachedCodexModels()
            guard !Task.isCancelled else { return }
            await codexModels.refresh()
            guard !Task.isCancelled, let self, self.acceptsWork else { return }
            for screen in self.screens { screen.applyModelCatalog(for: .codex, visibilityBefore: self.codexModelVisibility) }
        }
    }

    func applyModelPickerPreferences(for provider: AgentProvider, previousModelVisibility: ModelVisibility) {
        guard acceptsWork else { return }
        if previousModelVisibility != modelPickerPreferences.modelVisibility(for: provider) {
            for screen in screens { screen.applyModelCatalog(for: provider, visibilityBefore: previousModelVisibility) }
        }
        for screen in screens { screen.refreshReasoningVisibility() }
    }

    func retryMetadataSynchronization() {
        guard acceptsWork, !ownedTasks.isRunning(.metadataAction) else { return }
        ownedTasks.start(.metadataAction) { [weak self] in
            guard let self else { return }
            await metadataService.sync()
        }
    }

    func resolveMetadataConflict(threadID: String, keepLocal: Bool) {
        guard acceptsWork, !ownedTasks.isRunning(.metadataAction) else { return }
        isResolvingMetadata = true
        ownedTasks.start(.metadataAction) { [weak self] in
            guard let self else { return }
            defer { isResolvingMetadata = false }
            await metadataService.resolveConflict(sessionID: threadID, keepLocal: keepLocal)
            await metadataService.sync()
            guard acceptsWork, !Task.isCancelled, !keepLocal,
                  let shown = screenShowing(threadID), let thread = shown.activeConversation else { return }
            let saved = await metadataService.metadata(for: threadID)
            guard acceptsWork, shown.activeSessionID == threadID else { return }
            shown.restorePicker(from: thread, saved: saved)
            shown.refreshReasoningVisibility()
        }
    }

    private static func makeGatewayClient(for host: GatewayHostConfiguration, routes: GatewayRoutes, deviceTools: DeviceToolHost?,
                                          holdsConnection: @escaping @Sendable @MainActor () -> Bool = { false }) -> GatewayClient {
        do {
            return try GatewayClient(host: host, routes: routes, deviceTools: deviceTools,
                                     holdsConnection: holdsConnection)
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }

}
