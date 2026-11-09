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
    private let logger = AppLogger(category: "ChatRootView")

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
        .modifier(ChatLayoutObservation(context: ChatLayoutContext(window: window)))
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
            logger.notice("Received deep link: \(url.absoluteString)")
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
    @State private var showsAgents = false
    @SceneStorage("chat.isInspectorPresented") private var isInspectorPresented = false
    @State private var changeReview: ChangeReviewModel?
    @State private var isReviewingChanges = false
    #if os(iOS)
    @State private var voiceModeEntry: VoiceModeEntry?
    #endif
    @State private var isWindowVisible = true
    @State private var chatVisibility = SurfaceVisibilityState(isVisible: true)
    @State private var presentedQuestion: QuestionAddress?
    /// A question the transcript should reveal once its row or pending preview arrives.
    @State private var awaitedQuestionItemID: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @Environment(\.chatLayoutRecorder) private var layoutRecorder
    #endif
    @Environment(HostStore.self) private var gatewaySettings
    @Environment(AppThemeStore.self) private var themeStore

    // Drawer state
    @State private var drawerPresentation = DrawerPresentation(isOpen: false)
    @State private var viewID = String(UUID().uuidString.prefix(6))
    @State private var drawerLayout: ConversationDrawerLayout?
    @State private var drawerNotice: DrawerNotice?
    @State private var find = TranscriptFind()
    @State private var commandPalette: CommandPaletteCatalog?
    @State private var renamingPinnedChat: ConversationAddress?
    @State private var fileImportRequest = 0
    private let logger = AppLogger(category: "ChatScreen")

    private struct HistoryDrawerState: Equatable {
        let isOpen: Bool
        let overlaysTranscript: Bool
    }

    var body: some View {
        eventPresenter?.install(for: screen, perform: perform)
        let surface = ChatSidebarContainer(
            isPersistent: usesPersistentSidebar,
            presentation: drawerPresentation
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
        .pinnedChatRenamePrompt($renamingPinnedChat, workspace: workspace) { address in
            screen.openAddress == address ? screen.openConversationTitle : nil
        }
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
        .onChange(of: screen.workingDirectory) { followChangeReview() }
        .onChange(of: screen.activeSessionID) { followChangeReview() }
        .onChange(of: ObjectIdentifier(screen.target.gatewayClient)) { followChangeReview() }
        #if os(macOS)
        .background {
            ChatWindowActionsPublisher(
                workspace: workspace,
                window: window,
                screen: screen,
                find: find,
                drawerLayout: drawerLayout,
                isSidebarOpen: drawerPresentation.isOpen,
                isInspectorOpen: isInspectorPresented,
                isReviewingChanges: isReviewingChanges,
                newChat: { openNewChatWithKeyboard() },
                newChatInHomeFolder: openNewChatInHomeFolder,
                newChatOnHost: startNewChat(onHostID:),
                toggleSidebar: toggleHistory,
                toggleInspector: toggleInspector,
                reviewChanges: reviewChanges,
                focusComposer: { inputFocused = true },
                chooseFolder: openDirectoryPickerFromHeader,
                returnToParent: returnToAgentParent,
                selectConversation: { selectConversation($0) },
                fork: forkConversation,
                renamePinnedChat: { renamingPinnedChat = $0 },
                regenerateName: { address in
                    workspace.regenerateTitle(at: address) { screen.present(.conversation("Could not regenerate name: \($0)")) }
                },
                toggleAgents: toggleAgents,
                attachFile: { fileImportRequest += 1 },
                toggleCommandPalette: { actions in
                    commandPalette = commandPalette == nil ? CommandPaletteCatalog(actions: actions) : nil
                }
            )
        }
        #endif
        #if RC_PERF_HARNESS
        .background {
            PerformanceReplaySidebarPublisher(window: window, isOpen: { drawerPresentation.isOpen }, toggle: toggleHistory, select: selectConversation)
        }
        #endif
        return surface
        .onChange(of: usesPersistentSidebar, initial: true) { _, persistent in drawerPresentation.isOpen = persistent }
        .onAppear {
            VoiceModeDiagnostics.log("chat screen appeared")
            #if os(iOS)
            layoutRecorder?.drawerChanged(drawerPresentation.isOpen)
            #endif
        }
        .onChange(of: ObjectIdentifier(screen), initial: true) { _, _ in
            logger.notice("chat screen presents view=\(viewID) window=\(window.logID) target=\(screen.executionTarget.id) thread=\(screen.activeSessionID ?? "none")")
        }
        .modifier(WindowVisibility(isVisible: $isWindowVisible))
        .onChange(of: isWindowVisible, initial: true) { _, visible in
            workspace.setWindowVisible(window, isVisible: visible)
        }
        .onChange(of: isChatSurfaceVisible, initial: true) { _, visible in chatVisibility.isVisible = visible }
        .onDisappear {
            window.cancelComposerFocus()
            eventPresenter?.remove(screen)
        }
        .task(id: scenePhase == .active ? openingEvent : nil) {
            guard scenePhase == .active, let event = openingEvent, case .admitted = event else { return }
            openingEvent = nil
            event.performIfCurrent(in: window, navigationGeneration: workspace.navigationGeneration, perform: perform)
        }
        .modifier(DrawerOpenChange(presentation: drawerPresentation, action: drawerOpenChanged))
        .task(id: HistoryDrawerState(isOpen: isHistorySettledOpen, overlaysTranscript: !usesPersistentSidebar)) {
            workspace.setHistoryDrawerOpen(isHistorySettledOpen, overlaysTranscript: !usesPersistentSidebar, in: window)
        }
        .background {
            ConversationAgentsProbe(screen: screen, isPaused: scenePhase != .active)
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            SettingsView(workspace: workspace)
                .chatPresentationDiagnostics("sheet-settings")
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
                .environment(\.surfaceVisibility, SurfaceVisibility(chatVisibility))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    chatComposerInset.environment(\.surfaceVisibility, SurfaceVisibility(chatVisibility))
                }
                .composerAttachmentDrop(screen: screen)
                .modifier(ChatScreenChrome(
                    workspace: workspace,
                    screen: screen,
                    onReturnToParent: returnToAgentParent,
                    onOpenConversations: usesPersistentSidebar ? nil : {
                        dismissComposerFocus()
                        drawerPresentation.isOpen = true
                    },
                    onChooseFolder: openDirectoryPickerFromHeader,
                    onNewChatInHome: startNewChatInHome,
                    onNewChatOnHost: startNewChat(onHostID:),
                    isInspectorOpen: isInspectorPresented,
                    toggleInspector: toggleInspector,
                    isReviewingChanges: isReviewingChanges,
                    reviewChanges: reviewChanges
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
            .chatPresentationDiagnostics("cover-voice-mode")
        }
        #endif
    }

    private var chatBackground: some View {
        ThemedAppBackground()
    }

    private var chatTranscript: some View {
        ConversationTranscriptView(screen: screen, workspace: workspace, focus: $inputFocused,
                                   onDismissComposerFocus: dismissComposerFocus, showsAgents: $showsAgents,
                                   onOpenAgent: { _ = selectConversation($0) }, onReviewChanges: reviewChanges)
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
            isInspectorPresented: $isInspectorPresented,
            changeReview: changeReview,
            isReviewingChanges: $isReviewingChanges,
            onAddReviewComments: addReviewComments
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
            } else if screen.activeConversation?.acceptsDirectInput == false {
                SubagentControls(screen: screen, workspace: workspace, onViewQuestion: reveal(question:),
                                 onAskParent: askAgentParent(at:))
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
        #if os(iOS)
        .chatLayoutDiagnostics("composer")
        #endif
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
            || screen.target.fileImports.errorMessage != nil || screen.alert?.message != nil
    }

    private var blocksComposerFocus: Bool {
        blocksFilePresentation || renamingPinnedChat != nil
            || isReviewingChangesSheet
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

    private func toggleAgents() {
        dismissComposerFocus()
        showsAgents.toggle()
    }

    private func returnToAgentParent() {
        guard let parent = screen.agentParent else { return }
        _ = selectConversation(parent)
    }

    private func askAgentParent(at target: ConversationAddress) {
        guard let request = screen.subagentContext?.parentRequest else { return }
        let source = screen
        guard selectConversation(target) != .refusedWhileDictating else { return }
        Task {
            do {
                try await workspace.appendAgentRequest(request, to: target)
                guard let destination = window.selectedScreen, workspace.isShowingConversation(at: target, on: destination) else { return }
                window.requestComposerFocus(for: destination) {
                    guard !blocksComposerFocus else { return }
                    inputFocused = true
                }
            } catch is CancellationError {
            } catch {
                source.present(.conversation(error.localizedDescription))
            }
        }
    }

    private func drawerOpenChanged(_ open: Bool) {
        logger.notice("drawer state open=\(open) view=\(viewID) window=\(window.logID)")
        #if os(iOS)
        layoutRecorder?.drawerChanged(open)
        #endif
        if open {
            dismissComposerFocus()
            window.collapseDrawerReveals()
        }
    }

    private func dismissComposerFocus() {
        window.cancelComposerFocus()
        inputFocused = false
    }

    private var historyDrawer: some View {
        ConversationHistoryView(
            workspace: workspace,
            window: window,
            presentation: drawerPresentation,
            isVisible: isWindowVisible && isHistorySettledOpen && !isVoiceModePresented,
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
        #if RC_PERF_HARNESS
        #if os(iOS)
        PerfHarness.shared.willSelectRow(address)
        #endif
        #endif
        let outcome = workspace.switchConversation(to: address)
        #if RC_PERF_HARNESS
        #if os(iOS)
        if outcome != .changed { PerfHarness.shared.cancelRowSelection() }
        #endif
        #endif
        logger.notice(
            "history select view=\(viewID) address=\(address.id) outcome=\(String(describing: outcome)) presented=\(screen.executionTarget.id)|\(screen.activeSessionID ?? "none") \(workspace.windowDiagnostics(window))"
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

    private var isHistorySettledOpen: Bool {
        usesPersistentSidebar ? drawerPresentation.isOpen : drawerPresentation.isSettledOpen
    }

    private var isHistoryCovering: Bool {
        isHistorySettledOpen && !usesPersistentSidebar
    }

    private var isChatSurfaceVisible: Bool {
        isWindowVisible && !isHistoryCovering && !isVoiceModePresented && !isCameraPresented
    }

    private func toggleHistory() {
        dismissComposerFocus()
        drawerPresentation.isOpen.toggle()
    }

    private func toggleInspector() {
        if !isInspectorPresented { isReviewingChanges = false }
        isInspectorPresented.toggle()
    }

    private func reviewChanges() {
        #if os(macOS)
        if isInspectorPresented && isReviewingChanges {
            isInspectorPresented = false
            return
        }
        #endif
        guard let directory = screen.workingDirectory else { return }
        dismissComposerFocus()
        showChangeReview(of: directory)
    }

    private func showChangeReview(of directory: String) {
        let client = screen.target.gatewayClient
        if changeReview?.reviews(conversation: screen.activeSessionID, directory: directory, through: client) != true {
            changeReview?.stop()
            changeReview = ChangeReviewModel(conversation: screen.activeSessionID, directory: directory, client: client,
                                            summary: screen.changeSummary)
        }
        changeReview?.reopen()
        isReviewingChanges = true
        #if os(macOS)
        isInspectorPresented = true
        #endif
    }

    private func followChangeReview() {
        guard let model = changeReview, !reviewsCurrentConversation(model) else { return }
        model.stop()
        if model.writtenNoteCount == 0 {
            changeReview = nil
            if isShowingChangeReview, let directory = screen.workingDirectory {
                showChangeReview(of: directory)
                return
            }
        }
        isReviewingChanges = false
    }

    private func reviewsCurrentConversation(_ model: ChangeReviewModel) -> Bool {
        model.reviews(conversation: screen.activeSessionID, directory: screen.workingDirectory, through: screen.target.gatewayClient)
    }

    private var isShowingChangeReview: Bool {
        #if os(macOS)
        isReviewingChanges && isInspectorPresented
        #else
        isReviewingChanges
        #endif
    }

    private func addReviewComments(_ comments: String) -> Bool {
        guard let changeReview, reviewsCurrentConversation(changeReview), screen.insertReviewComments(comments) else { return false }
        #if os(iOS)
        isReviewingChanges = false
        #endif
        inputFocused = true
        HapticService.shared.play(.commit)
        return true
    }

    private var isReviewingChangesSheet: Bool {
        #if os(iOS)
        isReviewingChanges
        #else
        false
        #endif
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
        drawerPresentation.isOpen = false
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

private struct DrawerOpenChange: ViewModifier {
    let presentation: DrawerPresentation
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: presentation.isOpen) { _, open in action(open) }
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
