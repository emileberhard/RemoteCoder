import OSLog
import SwiftUI
#if os(iOS)
import LockedCameraCapture
#endif

enum ChatOpeningEvent: Equatable {
    case initial(ConversationWindowValue)
    case admitted(ExternalEvent, UUID)

    @MainActor
    func performIfCurrent(in window: ChatWindowModel, navigationGeneration: UUID, perform: (ExternalEvent) -> Void) {
        guard case .admitted(let event, let generation) = self,
              window.isAttached, generation == navigationGeneration else { return }
        perform(event)
    }
}

struct ChatRootView: View {
    var workspace: ChatWorkspaceModel
    @Binding private var sceneValue: ConversationWindowValue?
    @State private var openingEvent: ChatOpeningEvent?
    @State private var eventPreparation: (id: UUID, task: Task<Void, Never>)?
    @State private var eventError: String?
    @State private var eventPresenter = ChatScreenEvents()
    @State private var window: ChatWindowModel?
    @State private var composerSafeAreaOverlap: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    private let logger = Logger(subsystem: "RemoteCoder", category: "ChatRootView")

    init(workspace: ChatWorkspaceModel, sceneValue: Binding<ConversationWindowValue?>) {
        self.workspace = workspace
        _sceneValue = sceneValue
        _openingEvent = State(initialValue: sceneValue.wrappedValue.map(ChatOpeningEvent.initial))
    }

    var body: some View {
        let failure = workspace.draftRetirementFailure(for: window?.selectedTarget)
        ZStack {
            if let window, let screen = window.selectedScreen {
                ChatScreen(
                    workspace: workspace, window: window, screen: screen, openingEvent: $openingEvent, eventPresenter: eventPresenter,
                    composerSafeAreaOverlap: workspace.accountMigrationIssue == nil && failure == nil ? composerSafeAreaOverlap : 0
                )
            } else if let failure, failure.target == window?.selectedTarget {
                draftFailureNotice(failure)
            } else if workspace.selectedHost != nil {
                ProgressView("Loading workspace…")
            } else {
                GatewayHostsSettings(settings: workspace.settings, workspace: workspace) { hosts in
                    NavigationStack {
                        Form { hosts }
                            .navigationTitle("Gateway configuration")
                    }
                }
            }
        }
        .background { CompletionNotificationOverlay(workspace: workspace) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let issue = workspace.accountMigrationIssue {
                Text(issue).scaledFont(.footnote).foregroundStyle(.red).padding()
            }
            if let failure, window?.selectedScreen != nil || failure.target != window?.selectedTarget {
                draftFailureNotice(failure)
            }
        }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self, of: { min(ComposerMetrics.restingSafeAreaOverlap, $0.safeAreaInsets.bottom) }) {
            composerSafeAreaOverlap = $0
        }
        #endif
        #if os(macOS)
        .background {
            if let window { WindowSceneValueMirror(window: window, value: $sceneValue) }
        }
        #endif
        .background {
            if let window {
                Color.clear.frame(width: 0, height: 0)
                    .onAppear {
                        registerWithEventRouter(window)
                        if scenePhase == .active, case .initial(let value) = openingEvent {
                            perform(.open(value), in: window)
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active, eventPreparation == nil, case .initial(let value) = openingEvent {
                            perform(.open(value), in: window)
                        }
                    }
                    .modifier(WindowActivity(workspace: workspace, window: window))
            }
        }
        .onAppear {
            if window == nil {
                let value: ConversationWindowValue? = if case .initial(let value) = openingEvent { value } else { nil }
                window = workspace.attachWindow(opening: value)
            }
        }
        .onDisappear {
            eventPreparation?.task.cancel()
            eventPreparation = nil
            eventPresenter.clear()
            guard let attached = window else { return }
            window = nil
            workspace.detachWindow(attached)
        }
        .alert(workspace.notificationRoutingError == nil ? "Conversations" : "Notifications", isPresented: Binding(
            get: { workspace.notificationRoutingError != nil || eventError != nil },
            set: {
                if !$0 {
                    if workspace.notificationRoutingError != nil { workspace.notificationRoutingError = nil }
                    else { eventError = nil }
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.notificationRoutingError ?? eventError ?? "")
        }
        .onChange(of: workspace.settings.activeHostID) { _, _ in
            // Settings can also change the selection; the workspace only
            // changes which model is visible, never a model's destination.
            workspace.syncSelection()
        }
        .onChange(of: workspace.settings.hosts) { _, _ in workspace.reconcileHosts() }
        .onOpenURL { url in
            guard let event = ExternalEvent(url: url) else { return }
            logger.notice("Received deep link: \(url.absoluteString, privacy: .public)")
            workspace.events.receive(event)
        }
        #if os(iOS)
        .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in
            workspace.events.receive(.lockedCameraCaptures)
        }
        #endif
    }

    private func registerWithEventRouter(_ window: ChatWindowModel) {
        workspace.events.register(.init(
            presents: { [workspace, window] value in
                switch value {
                case .conversation(let address): workspace.isShowingConversation(at: address, on: window.selectedScreen)
                case .unsentDraft(let address): workspace.isShowingUnsentDraft(address, in: window)
                case .newChat: false
                }
            },
            perform: { event in
                if case .open = event { workspace.setWindowActive(window, isActive: true) }
                perform(event, in: window)
            }
        ), id: window.id)
    }

    private func perform(_ event: ExternalEvent, in window: ChatWindowModel) {
        eventPreparation?.task.cancel()
        eventPreparation = nil
        eventError = nil
        openingEvent = nil
        guard window.isAttached, !workspace.isQuiescing else { return }
        if workspace.keyWindow === window { workspace.supersedePendingNavigation() }
        let admittedGeneration = workspace.navigationGeneration
        switch event {
        case .completionNotificationTap: break
        case .quickAction, .presentVoiceCall, .open, .sharedItems, .lockedCameraCaptures:
            if let screen = window.selectedScreen, let perform = eventPresenter.handler(for: screen) {
                perform(event)
                return
            }
            if window.selectedScreen != nil {
                openingEvent = .admitted(event, admittedGeneration)
                return
            }
        }
        let id = UUID()
        let task = Task { @MainActor in
            defer { if eventPreparation?.id == id { eventPreparation = nil } }
            guard !Task.isCancelled, eventPreparation?.id == id, window.isAttached,
                  workspace.navigationGeneration == admittedGeneration else { return }
            do {
                if case .completionNotificationTap(let payload) = event {
                    await workspace.handleCompletionNotificationTap(payloadJSON: payload)
                } else {
                    try await workspace.prepareWindowForExternalEvent(event, in: window, admittedGeneration: admittedGeneration)
                    try Task.checkCancellation()
                    guard eventPreparation?.id == id, window.isAttached,
                          workspace.navigationGeneration == admittedGeneration else { throw CancellationError() }
                    openingEvent = .admitted(event, admittedGeneration)
                }
            } catch is CancellationError {
                if eventPreparation?.id == id { openingEvent = nil }
            } catch {
                guard !Task.isCancelled, eventPreparation?.id == id else { return }
                openingEvent = nil
                eventError = error.localizedDescription
            }
        }
        eventPreparation = (id, task)
    }

    private func draftFailureNotice(_ failure: (target: ExecutionTarget, message: String)) -> some View {
        ComposerDraftFailureNotice(message: failure.message, retry: {
            workspace.retryDraftRetirement(failure.target)
        })
        .disabled(workspace.isRetryingDraftRetirement(failure.target))
    }
}

@MainActor
private final class ChatScreenEvents {
    private var presentation: (screen: ObjectIdentifier, perform: @MainActor (ExternalEvent) -> Void)?

    func install(for screen: ChatScreenModel, perform: @escaping @MainActor (ExternalEvent) -> Void) {
        presentation = (ObjectIdentifier(screen), perform)
    }

    func handler(for screen: ChatScreenModel) -> (@MainActor (ExternalEvent) -> Void)? {
        guard presentation?.screen == ObjectIdentifier(screen) else { return nil }
        return presentation?.perform
    }

    func remove(_ screen: ChatScreenModel) {
        if presentation?.screen == ObjectIdentifier(screen) { presentation = nil }
    }

    func clear() { presentation = nil }
}

private struct ChatScreen: View {
    @Bindable var workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    @Bindable var screen: ChatScreenModel
    @Binding var openingEvent: ChatOpeningEvent?
    weak var eventPresenter: ChatScreenEvents?
    let composerSafeAreaOverlap: CGFloat
    @Namespace private var chromeNamespace
    @Namespace private var composerNS
    #if os(iOS)
    @State private var inputFocused = false
    #else
    @FocusState private var inputFocused: Bool
    #endif
    @State private var showDirectoryPicker = false
    @State private var composerPresentations = ComposerPresentations()
    #if os(iOS)
    @State private var showSettings = false
    #else
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var presentedAgents: ConversationAgentsModel?
    @SceneStorage("chat.isInspectorPresented") private var isInspectorPresented = false
    @State private var returningToAgentParent = false
    @State private var agentNavigationError: String?
    #if os(iOS)
    @State private var voiceModeEntry: VoiceModeEntry?
    #endif
    @State private var isWindowVisible = true
    @State private var presentedQuestion: QuestionAddress?
    /// A question the transcript should reveal once its row or pending preview arrives.
    @State private var awaitedQuestionItemID: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HostStore.self) private var gatewaySettings
    @Environment(AppThemeStore.self) private var themeStore

    // Drawer state
    @State private var isHistoryOpen = false
    @State private var viewID = String(UUID().uuidString.prefix(6))
    @State private var drawerLayout: ConversationDrawerLayout?
    @State private var drawerNotice: DrawerNotice?
    @State private var find = TranscriptFind()
    @State private var commandPalette: CommandPaletteCatalog?
    @State private var pinRequest: ConversationPinRequest?
    @State private var fileImportRequest = 0
    private let logger = Logger(subsystem: "RemoteCoder", category: "ChatScreen")

    private struct HistoryDrawerState: Equatable {
        let isOpen: Bool
        let overlaysTranscript: Bool
    }

    var body: some View {
        eventPresenter?.install(for: screen, perform: perform)
        return ChatSidebarContainer(
            isPersistent: usesPersistentSidebar,
            isOpen: $isHistoryOpen,
            onBeginOpening: { dismissComposerFocus() }
        ) {
            mainChatSurface
        } sidebar: {
            historyDrawer
        }
        #if os(macOS)
        .defaultFocus($inputFocused, true)
        #endif
        .modifier(conversationDetails)
        .overlay {
            #if os(macOS)
            if !screen.target.isGatewayConnected { ConnectionEdgeGlow(connectivity: screen.target.gatewayConnectivity) }
            #else
            ConnectionEdgeGlow(connectivity: screen.target.gatewayConnectivity)
            #endif
        }
        .overlay {
            if let commandPalette {
                CommandPalette(catalog: commandPalette, dismiss: { self.commandPalette = nil })
            }
        }
        .conversationPinPrompt($pinRequest, workspace: workspace)
        #if os(iOS)
        .reasoningPickerOverlay()
        #endif
        .directoryQuickSwitchOverlay(isEnabled: !isHistoryCovering && !showDirectoryPicker && !isShowingSettingsSheet && !isVoiceModePresented)
        .onChange(of: blocksComposerFocus) { _, blocked in
            if blocked { window.cancelComposerFocus() }
        }
        .onChange(of: screen.acceptsConversationInput) { _, acceptsInput in
            if !acceptsInput { composerPresentations.dismiss() }
        }
        #if os(macOS) || RC_PERF_HARNESS
        .background {
            ChatWindowActionsPublisher(
                workspace: workspace,
                window: window,
                screen: screen,
                find: find,
                drawerLayout: drawerLayout,
                isSidebarOpen: isHistoryOpen,
                isInspectorOpen: isInspectorPresented,
                newChat: { openNewChatWithKeyboard() },
                newChatInHomeFolder: openNewChatInHomeFolder,
                newChatOnHost: startNewChat(onHostID:),
                toggleSidebar: toggleHistory,
                toggleInspector: toggleInspector,
                focusComposer: { inputFocused = true },
                chooseFolder: openDirectoryPickerFromHeader,
                returnToParent: returningToAgentParent ? nil : { returningToAgentParent = true },
                selectConversation: { selectConversation($0) },
                fork: forkConversation,
                requestPinName: { pinRequest = $0 },
                showAgents: showAgents,
                attachFile: { fileImportRequest += 1 },
                toggleCommandPalette: { actions in
                    commandPalette = commandPalette == nil ? CommandPaletteCatalog(actions: actions) : nil
                }
            )
        }
        #endif
        .onChange(of: usesPersistentSidebar, initial: true) { _, persistent in isHistoryOpen = persistent }
        .onAppear {
            VoiceModeDiagnostics.log("chat screen appeared")
        }
        .onChange(of: ObjectIdentifier(screen), initial: true) { _, _ in
            logger.notice("chat screen presents view=\(viewID, privacy: .public) window=\(window.logID, privacy: .public) target=\(screen.executionTarget.id, privacy: .public) thread=\(screen.activeSessionID ?? "none", privacy: .public)")
        }
        .modifier(WindowVisibility(isVisible: $isWindowVisible))
        .onChange(of: isWindowVisible, initial: true) { _, visible in
            workspace.setWindowVisible(window, isVisible: visible)
        }
        .onDisappear {
            window.cancelComposerFocus()
            eventPresenter?.remove(screen)
        }
        .task(id: scenePhase == .active ? openingEvent : nil) {
            guard scenePhase == .active, let event = openingEvent, case .admitted = event else { return }
            openingEvent = nil
            event.performIfCurrent(in: window, navigationGeneration: workspace.navigationGeneration, perform: perform)
        }
        .onChange(of: isHistoryOpen) { _, open in
            logger.notice("drawer state open=\(open, privacy: .public) view=\(viewID, privacy: .public) window=\(window.logID, privacy: .public)")
            if open {
                dismissComposerFocus()
            }
        }
        .task(id: HistoryDrawerState(isOpen: isHistoryOpen, overlaysTranscript: !usesPersistentSidebar)) {
            workspace.setHistoryDrawerOpen(isHistoryOpen, overlaysTranscript: !usesPersistentSidebar, in: window)
        }
        .background {
            ConversationAgentsProbe(screen: screen, isPaused: scenePhase != .active)
        }
        .task(id: returningToAgentParent) {
            guard returningToAgentParent else { return }
            defer { returningToAgentParent = false }
            do {
                try await workspace.returnToAgentParent()
            } catch is CancellationError {
            } catch {
                agentNavigationError = error.localizedDescription
            }
        }
        .alert("Conversation unavailable", isPresented: Binding(get: { agentNavigationError != nil }, set: { if !$0 { agentNavigationError = nil } })) {
            Button("OK", role: .cancel) { agentNavigationError = nil }
        } message: {
            Text(agentNavigationError ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            SettingsView(workspace: workspace)
        }
        #endif
        .environment(\.chromeTransitionNamespace, chromeNamespace)
    }

    private func perform(_ event: ExternalEvent) {
        switch event {
        case .quickAction(let request):
            switch request.action {
            case .newChat:
                openNewChatInHomeFolder()
            case .voiceChat:
                #if os(iOS)
                VoiceModeDiagnostics.log("voice request routing")
                openVoiceChat(
                    startsFreshChat: request.startsFreshVoiceChat,
                    configuration: request.voiceConfiguration
                )
                #endif
            case .camera:
                #if os(iOS)
                if let destination = openNewChatWithKeyboard() {
                    dismissComposerFocus()
                    destination.openCamera { draft in
                        composerPresentations.presentCamera(for: destination, draft: draft)
                    }
                }
                #endif
            }
        #if os(iOS)
        case .presentVoiceCall(let callID):
            presentVoiceCall(callID)
        #else
        case .presentVoiceCall:
            break
        #endif
        case .open(.conversation(let address)):
            workspace.setWindowActive(window, isActive: true)
            selectConversation(address)
        case .open(.newChat):
            workspace.setWindowActive(window, isActive: true)
            openNewChatInHomeFolder()
        case .open(.unsentDraft(let address)):
            workspace.setWindowActive(window, isActive: true)
            openUnsentDraft(address)
        case .sharedItems(let id):
            openNewChatWithKeyboard()?.receiveSharedItems(id)
        case .lockedCameraCaptures:
            #if os(iOS)
            openNewChatWithKeyboard()?.receiveLockedCameraCaptures()
            #endif
        case .completionNotificationTap(let payloadJSON):
            Task { await workspace.handleCompletionNotificationTap(payloadJSON: payloadJSON) }
        }
    }

    private func openNewChatInHomeFolder() {
        guard let destination = openNewChatWithKeyboard() else { return }
        Task { await destination.updateWorkingDirectoryToRemoteHome() }
    }

    @discardableResult
    private func openNewChatWithKeyboard() -> ChatScreenModel? {
        closeHistoryDrawer()
        #if os(iOS)
        composerPresentations.camera = nil
        voiceModeEntry = nil
        #endif
        showDirectoryPicker = false
        closeSettingsSheet()

        guard let destination = workspace.startNewConversation(onHostID: screen.hostID) else { return nil }

        // If we were in voice mode, give the cover a moment to dismiss before focusing.
        window.requestComposerFocus(for: destination) {
            guard !blocksComposerFocus else { return }
            inputFocused = true
        }
        return destination
    }

    #if os(iOS)
    /// The audio route and the system conversation are device-wide, so the voice
    /// surface always belongs to the host whose thread the live call is bound to.
    /// Only when no call is up does it follow the sidebar selection.
    private var voiceScreen: ChatScreenModel {
        workspace.voiceCallOwner ?? screen
    }

    private func openVoiceChat(startsFreshChat: Bool, configuration: RemoteCoderVoiceConfiguration? = nil) {
        VoiceModeDiagnostics.log("voice open started fresh=\(startsFreshChat)")
        closeHistoryDrawer()
        showDirectoryPicker = false
        showSettings = false

        dismissComposerFocus()
        let selected = screen
        Task { @MainActor in
            do {
                guard try await workspace.prepareVoiceCall(
                    from: selected, startsFreshChat: startsFreshChat, configuration: configuration
                ) != nil else { return }
            } catch {
                (workspace.selectedScreen ?? selected).present(.conversation(error.localizedDescription))
                return
            }
            voiceModeEntry = .startCall
            VoiceModeDiagnostics.log("voice cover requested")
        }
    }

    private func presentVoiceCall(_ callID: UUID) {
        guard workspace.selectLiveVoiceCall(callID) else {
            VoiceModeDiagnostics.log("voice call presentation dropped call=\(callID)")
            return
        }
        closeHistoryDrawer()
        showDirectoryPicker = false
        showSettings = false
        dismissComposerFocus()
        voiceModeEntry = .presentCall(callID)
        VoiceModeDiagnostics.log("voice cover requested call=\(callID)")
    }
    #endif

    private var voiceModeOpener: (() -> Void)? {
        #if os(iOS)
        return { openVoiceChat(startsFreshChat: false) }
        #else
        return nil
        #endif
    }

    private var mainChatSurface: some View {
        Group {
            chatTranscript
                .environment(\.visualsVisible, isWindowVisible && !isHistoryCovering && !isVoiceModePresented && !isCameraPresented)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    chatComposerInset.environment(\.visualsVisible, isWindowVisible && !isHistoryCovering && !isVoiceModePresented && !isCameraPresented)
                }
                .composerAttachmentDrop(screen: screen)
                .safeAreaBar(edge: .top, spacing: 0) { HostFileStatusBar(opener: screen.target.fileOpener) }
                .modifier(ChatScreenChrome(
                    workspace: workspace,
                    screen: screen,
                    isReturningToParent: returningToAgentParent,
                    onReturnToParent: { returningToAgentParent = true },
                    onOpenConversations: usesPersistentSidebar ? nil : {
                        dismissComposerFocus()
                        isHistoryOpen = true
                    },
                    onChooseFolder: openDirectoryPickerFromHeader,
                    onNewChatInHome: startNewChatInHome,
                    onNewChatOnHost: startNewChat(onHostID:),
                    isInspectorOpen: isInspectorPresented,
                    toggleInspector: toggleInspector
                ))
                .background { chatBackground }
            .modifier(HostFilePresentation(opener: screen.target.fileOpener, isBlocked: blocksFilePresentation, scope: nil))
            .modifier(ChatScreenPresentations(
                workspace: workspace, screen: screen,
                presentedQuestion: $presentedQuestion, showDirectoryPicker: $showDirectoryPicker))
            .onChange(of: screen.questionFocusRequest, initial: true) { _, request in
                guard let request else { return }
                screen.clearQuestionFocusRequest()
                awaitedQuestionItemID = request.itemID
                if let address = screen.questionAddress(itemID: request.itemID) {
                    Task { await screen.refreshQuestion(address) }
                }
                revealAwaitedQuestionIfPossible()
            }
            .onChange(of: awaitedQuestion) { _, _ in revealAwaitedQuestionIfPossible() }
            .onChange(of: isVoiceModePresented) { _, presented in
                if presented {
                    dismissComposerFocus()
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $voiceModeEntry) { entry in
            VoiceModeView(screen: voiceScreen, entry: entry, isPresented: Binding(
                get: { voiceModeEntry != nil },
                set: { if !$0 { voiceModeEntry = nil } }
            ))
            .navigationTransition(.zoom(sourceID: "voice-mode", in: composerNS))
        }
        #endif
    }

    private var chatBackground: some View {
        ThemedAppBackground()
    }

    private var chatTranscript: some View {
        ConversationTranscriptView(screen: screen, focus: $inputFocused,
                                   onDismissComposerFocus: dismissComposerFocus, onShowAgents: showAgents)
            #if os(macOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                if find.isPresented { TranscriptFindBar(find: find, screen: screen) }
            }
            #else
            .overlay(alignment: .topTrailing) {
                if find.isPresented {
                    TranscriptFindBar(find: find, screen: screen)
                        .padding(12)
                }
            }
            #endif
    }

    private var conversationDetails: ConversationDetailsPresentation {
        ConversationDetailsPresentation(
            workspace: workspace,
            screen: screen,
            presentedAgents: $presentedAgents,
            isInspectorPresented: $isInspectorPresented,
            onParentRequestSent: { inputFocused = true }
        )
    }

    private var chatComposerInset: some View {
        Group {
            if screen.acceptsConversationInput {
                ChatComposerView(
                    screen: screen,
                    focus: $inputFocused,
                    presentations: composerPresentations,
                    onCancelComposerFocus: window.cancelComposerFocus,
                    onOpenVoiceMode: voiceModeOpener,
                    namespace: composerNS,
                    onOpenPendingQuestion: {
                        guard let prompt = screen.pendingQuestion else { return }
                        reveal(question: prompt)
                    },
                    modelOptions: workspace.modelOptions(for: screen),
                    onSelectModel: { workspace.selectModel($0) },
                    onSend: workspace.send,
                    onQueue: workspace.queue,
                    fileImportRequest: fileImportRequest
                )
            } else {
                VStack(spacing: 8) {
                    Text("Manage this agent from its parent conversation.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                    if let question = screen.pendingQuestion {
                        Button("View question") { reveal(question: question) }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        #if os(macOS)
        .padding(.bottom, 8)
        #else
        .padding(.bottom, inputFocused ? 8 : -composerSafeAreaOverlap)
        #endif
        .scaledFrame(maxWidth: ReadableContentWidth.composer)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Scrolls to the loaded card, or opens the same card in a sheet when its page is not loaded.
    private func reveal(question prompt: QuestionPrompt) {
        let rowID = ChatStreamItem.questionRowID(itemID: prompt.itemID)
        if screen.streamItems.contains(where: { $0.id == rowID }) {
            dismissComposerFocus()
            screen.revealTranscriptRow(rowID)
        } else {
            showDirectoryPicker = false
            closeSettingsSheet()
            presentedQuestion = screen.questionAddress(itemID: prompt.itemID)
        }
    }

    // An idle question router must not observe the entire streaming transcript.
    private var awaitedQuestion: QuestionPrompt? {
        guard let itemID = awaitedQuestionItemID else { return nil }
        let rowID = ChatStreamItem.questionRowID(itemID: itemID)
        if let row = screen.streamItems.first(where: { $0.id == rowID }), case .question(let prompt) = row {
            return prompt
        }
        return screen.questionPrompts[itemID]
    }

    private func revealAwaitedQuestionIfPossible() {
        guard let prompt = awaitedQuestion else { return }
        awaitedQuestionItemID = nil
        reveal(question: prompt)
    }

    private var isShowingSettingsSheet: Bool {
        #if os(iOS)
        showSettings
        #else
        false
        #endif
    }

    private func closeSettingsSheet() {
        #if os(iOS)
        showSettings = false
        #endif
    }

    private var blocksFilePresentation: Bool {
        isHistoryCovering || showDirectoryPicker || isShowingSettingsSheet || isVoiceModePresented || isCameraPresented || presentedQuestion != nil
            || screen.target.speech.lastError != nil || screen.target.fileImports.errorMessage != nil || screen.alert?.message != nil
    }

    private var blocksComposerFocus: Bool {
        blocksFilePresentation || presentedAgents != nil || agentNavigationError != nil || pinRequest != nil
            || commandPalette != nil || screen.target.voiceError != nil || composerPresentations.blocksFocus
    }

    private var isVoiceModePresented: Bool {
        #if os(iOS)
        voiceModeEntry != nil
        #else
        false
        #endif
    }

    private var isCameraPresented: Bool {
        #if os(iOS)
        composerPresentations.camera != nil
        #else
        false
        #endif
    }

    private func showAgents(_ agents: ConversationAgentsModel) {
        dismissComposerFocus()
        conversationDetails.show(agents)
    }

    private func dismissComposerFocus() {
        window.cancelComposerFocus()
        inputFocused = false
    }

    private var historyDrawer: some View {
        historyDrawerContent.environment(\.visualsVisible, isWindowVisible && isHistoryOpen && !isVoiceModePresented)
    }

    private var historyDrawerContent: some View {
        ConversationHistoryView(
            workspace: workspace,
            window: window,
            isOpen: isHistoryOpen,
            layout: $drawerLayout,
            notice: $drawerNotice,
            onSelect: selectConversation,
            onOpenDraft: openUnsentDraft,
            onStartNew: startNewChat(onHostID:),
            onShowSettings: {
                dismissComposerFocus()
                closeHistoryDrawer()
                #if os(iOS)
                showSettings = true
                #else
                openSettings()
                #endif
            },
            onFork: forkConversation,
            onFocusComposer: { inputFocused = true }
        )
    }

    private func forkConversation(_ address: ConversationAddress) {
        guard !workspace.refusesSwitchWhileDictating else { return presentDictationRefusal() }
        dismissComposerFocus()
        closeHistoryDrawer()
        Task {
            await workspace.forkConversation(at: address)
        }
    }

    @discardableResult
    private func selectConversation(_ address: ConversationAddress) -> ChatWorkspaceModel.ConversationSwitchOutcome {
        let outcome = workspace.switchConversation(to: address)
        logger.notice(
            "history select view=\(viewID, privacy: .public) address=\(address.id, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) presented=\(screen.executionTarget.id, privacy: .public)|\(screen.activeSessionID ?? "none", privacy: .public) \(workspace.windowDiagnostics(window), privacy: .public)"
        )
        guard outcome != .refusedWhileDictating else {
            presentDictationRefusal()
            return outcome
        }
        #if os(iOS)
        dismissComposerFocus()
        #endif
        closeHistoryDrawer()
        if outcome == .changed {
            HapticService.shared.play(.selection)
        }
        return outcome
    }

    private var usesPersistentSidebar: Bool {
        SidebarPresentation.isPersistent(sizeClass: horizontalSizeClass)
    }

    private var isHistoryCovering: Bool {
        isHistoryOpen && !usesPersistentSidebar
    }

    private func toggleHistory() {
        dismissComposerFocus()
        isHistoryOpen.toggle()
    }

    private func toggleInspector() {
        isInspectorPresented.toggle()
    }

    private func openUnsentDraft(_ address: UnsentDraftAddress) {
        let outcome = workspace.openUnsentDraft(address, in: window)
        guard outcome != .refusedWhileDictating else { return presentDictationRefusal() }
        #if os(iOS)
        dismissComposerFocus()
        #endif
        closeHistoryDrawer()
        if outcome == .changed { HapticService.shared.play(.selection) }
    }

    private func startNewChat(onHostID hostID: UUID) {
        guard !workspace.refusesSwitchWhileDictating else { return presentDictationRefusal() }
        dismissComposerFocus()
        workspace.startNewConversation(onHostID: hostID)
        closeHistoryDrawer()
    }

    private func startNewChatInHome() {
        guard let destination = workspace.startNewConversation(onHostID: screen.hostID) else { return }
        Task { await destination.updateWorkingDirectoryToRemoteHome() }
    }

    private func closeHistoryDrawer() {
        guard !usesPersistentSidebar else { return }
        isHistoryOpen = false
    }

    private func presentDictationRefusal() {
        let notice = DrawerNotice(message: "Finish dictating before switching chats.")
        drawerNotice = notice
        HapticService.shared.play(.refused)
        AccessibilityNotification.Announcement(notice.message).post()
    }

    private func openDirectoryPickerFromHeader() {
        guard showDirectoryPicker == false else { return }
        dismissComposerFocus()
        showDirectoryPicker = true
    }
}

private struct ConversationAgentsProbe: View {
    let screen: ChatScreenModel
    let isPaused: Bool

    private struct Key: Equatable {
        let agents: UUID?
        let children: Set<String>
        let tailReady: Bool
        let isPaused: Bool
    }

    var body: some View {
        let agents = screen.conversationAgents
        Color.clear
            .task(id: Key(agents: agents?.id, children: screen.currentConversationChildren,
                          tailReady: screen.loadingTranscriptID == nil && screen.historyEdges.status[.newer] != .failed, isPaused: isPaused)) {
                guard !isPaused, screen.loadingTranscriptID == nil, screen.historyEdges.status[.newer] != .failed, let agents else { return }
                agents.observeChildren(screen.currentConversationChildren)
                await agents.refreshIfNeeded()
            }
    }
}
