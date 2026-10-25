import Foundation
import Observation
import OSLog
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ChatScreenModel: HistoryEdgeHost, RealtimeVoicePreparationHost {
    private enum OwnedTask: Hashable {
        case snapshots, resume, settingsUpdate, compaction, compactionStatus, draftLoad, sharedItems(UUID)
        case cameraCaptures
    }

    private(set) var currentDraft: ComposerDraft?
    private(set) var currentConversationID = UUID()
    // Drives the transcript view's identity. Changes only on explicit
    // conversation switches (resume/fork/new chat), never when a draft chat
    // gains a session id mid-turn, so the scroll view is never recreated
    // while the user is watching it.
    private(set) var transcriptIdentity: String = UUID().uuidString {
        didSet { if oldValue != transcriptIdentity { fileOpener.invalidate() } }
    }
    private(set) var transcriptReadingPosition = TranscriptReadingPosition()
    private(set) var transcriptRowPresentations = TranscriptRowPresentations()
    @ObservationIgnored let transcriptSurfaceID = UUID()
    private(set) var presentation = TargetPresentation()
    private(set) var activeSessionID: String?
    private(set) var activeModelProvider: ThreadModelProvider?
    var activeConversation: ConversationHeader?
    private(set) var loadingTranscriptID: String?
    private(set) var alert: ScreenAlert?
    private(set) var conversationAgents: ConversationAgentsModel?
    private(set) var contextWindowUsage: ContextWindowUsage?
    private(set) var compaction: ConversationCompaction?
    @ObservationIgnored private var preparingRenderWindows: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private(set) var messages: [ChatMessage] = [] {
        didSet { target.retainPresentedRenders() }
    }

    var renderWindowIDs: Set<UUID> {
        Set(messages.map(\.id)).union(preparingRenderWindows.values.flatMap { $0 })
    }
    private(set) var forkableMessageIDs: Set<UUID> = []
    private(set) var composerSends = 0
    @ObservationIgnored private var currentStreamItems: [ChatStreamItem] = []
    private(set) var streamItems: [ChatStreamItem] {
        get {
            access(keyPath: \.streamItems)
            return currentStreamItems
        }
        set {
            if newValue.differsOnlyInStreamingText(from: currentStreamItems) {
                currentStreamItems = newValue
            } else {
                withMutation(keyPath: \.streamItems) { currentStreamItems = newValue }
            }
        }
    }
    private(set) var canPrefetchOlderHistory = false
    /// The earliest unanswered model question in the visible conversation.
    private(set) var pendingQuestion: QuestionPrompt?
    private(set) var questionPrompts: [String: QuestionPrompt] = [:]
    private(set) var pendingTranscriptRequest: TranscriptRowRequest?
    @ObservationIgnored private(set) var selectedConversation: ConversationSession?
    @ObservationIgnored private var presentedRevision: UInt64 = 0
    @ObservationIgnored private var presentedCompletionAt: Int64?
    @ObservationIgnored private var markedCompletion: SeenCompletion?
    @ObservationIgnored private(set) var resumeLoadID: UUID?
    @ObservationIgnored private var showsRecentPresentation = false
    @ObservationIgnored private(set) var draftDestination: ComposerDraftStore.Destination
    private(set) var newChatDraftID: UUID
    @ObservationIgnored private var setupChoices: UInt64 = 0
    @ObservationIgnored var idleQuestionSubmissionBlock: (@MainActor () -> String?)?

    @ObservationIgnored let dictation: DictationSession
    @ObservationIgnored lazy var historyEdges = HistoryEdgeReader(
        host: self, historyService: historyService, conversations: conversations, networkPolicy: HistoryNetworkPolicy())
    @ObservationIgnored var historyOpenSignpost = HistoryOpenSignpost()

    @ObservationIgnored private let ownedTasks = OwnedTasks<OwnedTask>()
    @ObservationIgnored private let headerNavigation = ConversationHeaderNavigation()
    @ObservationIgnored private lazy var voicePreparation = RealtimeVoicePreparation(
        host: self, gateway: target.gatewayClient, conversations: conversations, history: historyService,
        voiceHistory: target.voiceHistoryStore, drafts: drafts)
    @ObservationIgnored let target: ChatTargetModel
    @ObservationIgnored let drafts: ComposerDraftStore
    @ObservationIgnored private let conversations: ConversationSessions
    @ObservationIgnored private let renderedMessages: RenderedMessageStore
    @ObservationIgnored let htmlVisualPreparation: HTMLVisualPreparation
    @ObservationIgnored private let fileOpener: HostFileOpener
    @ObservationIgnored private let historyService: GatewayHistoryService
    @ObservationIgnored private let logger = Logger(subsystem: "RemoteCoder", category: "ChatScreen")
    private static let streamingMotionLogger = Logger(subsystem: "emileberhard.RemoteCoder", category: "streaming-motion")

    init(target: ChatTargetModel, newChat: UUID) {
        self.target = target
        newChatDraftID = newChat
        draftDestination = .newChat(newChat)
        drafts = target.drafts
        conversations = target.conversations
        renderedMessages = target.renderedMessages
        htmlVisualPreparation = HTMLVisualPreparation(renderer: target.hostServices.htmlVisualRenderer)
        fileOpener = target.fileOpener
        historyService = target.historyService
        dictation = DictationSession(host: target, drafts: target.drafts)
        workingDirectory = HostPreferences.workingDirectory(hostID: target.hostID, defaults: target.chatDefaults)
        let model = target.newChatDefaultModel().model
        let reasoning = NewChatDefaults.reasoningSelection(defaults: target.chatDefaults)
        pickerSelection = ConversationSettingsSelection(
            model: model, reasoning: model.map { target.modelPickerPreferences.clamped(reasoning, for: $0) } ?? reasoning,
            fastMode: .selection(NewChatDefaults.fastModeEnabled(defaults: target.chatDefaults)))
        currentDraft = drafts.cachedDraft(for: draftDestination)
        if let draft = currentDraft {
            currentConversationID = draft.id
            adoptSetup(of: draft)
        } else {
            selectDraft(draftDestination)
        }
    }

    func showPreview(_ previewMessages: [ChatMessage]) {
        messages = previewMessages
        streamItems = previewMessages.map(ChatStreamItem.message)
    }

    func present(_ alert: ScreenAlert) {
        self.alert = alert
    }

    func dismissAlert() {
        alert = nil
    }

    // MARK: - Draft

    func selectDraft(_ destination: ComposerDraftStore.Destination) {
        drafts.requestFlush()
        ownedTasks.cancel(.draftLoad)
        ownedTasks.cancel(.cameraCaptures)
        draftDestination = destination
        currentDraft = drafts.cachedDraft(for: destination)
        guard currentDraft == nil else { return }
        ownedTasks.start(.draftLoad) { [weak self] in
            _ = await self?.prepareDraft(destination)
        }
    }

    func prepareDraft() async -> Bool {
        await prepareDraft(draftDestination)
    }

    private func prepareDraft(_ destination: ComposerDraftStore.Destination) async -> Bool {
        let choices = setupChoices
        let draft = await drafts.draft(for: destination)
        guard target.acceptsWork, !Task.isCancelled, draftDestination == destination else { return false }
        currentDraft = draft
        if let draft, ComposerDraftStore.Destination.isNewChat(key: destination.key) {
            currentConversationID = draft.id
            if setupChoices == choices { adoptSetup(of: draft) } else { recordNewChatSetup() }
        }
        resumeStagedUploads()
        return draft != nil
    }

    var draftErrorMessage: String? {
        drafts.errorMessage ?? drafts.destinationError(for: draftDestination)
    }

    func retryDraft() {
        if currentDraft == nil { selectDraft(draftDestination) }
        else { drafts.requestFlush() }
    }

    // MARK: - Presented conversation

    func revealTranscriptRow(_ rowID: String) {
        requestTranscriptRow(rowID, anchor: .center, motion: .instant)
    }

    func requestTranscriptRow(_ rowID: String, anchor: UnitPoint, motion: TranscriptRowRequest.Motion) {
        pendingTranscriptRequest = TranscriptRowRequest(rowID: rowID,
            token: (pendingTranscriptRequest?.token ?? 0) + 1, anchor: anchor, motion: motion)
    }

    /// Internal so busy-state tests can place the conversation the user has open.
    func setActiveSessionID(_ sessionID: String?) {
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if let trimmed, trimmed.isEmpty == false {
            normalized = trimmed
        } else {
            normalized = nil
        }

        if normalized != activeSessionID {
            transcriptReadingPosition.capture(scope: transcriptSurfaceID)
            rememberConversationSettings()
            conversationAgents = normalized.map(target.agents(threadID:))
            presentedCompletionAt = nil
            contextWindowUsage = nil
            activeModelProvider = nil
        }
        activeSessionID = normalized
        target.activeSessionChanged(to: normalized)
    }

    func adoptModelProvider(_ modelProvider: String?, threadID: String) {
        guard threadID == activeSessionID, let provider = ThreadModelProvider(modelProvider, threadID: threadID),
              provider != activeModelProvider else { return }
        activeModelProvider = provider
    }

    func adoptReportedModel(_ modelID: String?, threadID: String, selectionRevision: UInt64) {
        guard activeModelProvider?.externalID != nil, let modelID, modelID != selectedModel?.id,
              selectionIsCurrent(revision: selectionRevision, threadID: threadID),
              let option = modelOption(id: modelID, threadID: threadID, effort: reasoningSelection.effort?.rawValue,
                                       fastMode: fastModeSelection == true) else { return }
        pickerSelection.adoptModel(option)
        refreshReasoningVisibility()
    }

    private func modelOption(id: String, threadID: String, effort: String?, fastMode: Bool) -> ModelOption? {
        target.modelCatalog.option(id: id, threadID: threadID, modelProvider: threadID == activeSessionID ? activeModelProvider : nil,
                                   effort: effort, fastMode: fastMode)
    }

    func beginNewChat() {
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            messages.removeAll()
        }
        activeConversation = nil
        setActiveSessionID(nil)
        htmlVisualPreparation.cancelDemand()
        currentConversationID = currentDraft?.id ?? UUID()
        transcriptReadingPosition = TranscriptReadingPosition()
        transcriptRowPresentations = TranscriptRowPresentations()
        transcriptIdentity = UUID().uuidString
    }

    func showTranscript(identity: String, threadID: String) {
        transcriptIdentity = identity
        resetRendering()
        let retained = target.recentPresentation(threadID: threadID)?.session
        transcriptReadingPosition = retained?.readingPosition ?? TranscriptReadingPosition()
        transcriptRowPresentations = retained?.rowPresentations ?? TranscriptRowPresentations()
        showRecentPresentation(threadID: threadID)
    }

    func adopt(_ session: ConversationSession) async {
        currentConversationID = session.conversationID
        observe(session)
        presentedRevision = 0
        await publish(await session.snapshot())
    }

    func resetRendering() {
        htmlVisualPreparation.cancelDemand()
        compaction = nil
        pendingTranscriptRequest = nil
        messages = []
        forkableMessageIDs = []
        streamItems = []
        canPrefetchOlderHistory = false
        pendingQuestion = nil
        questionPrompts = [:]
        selectedConversation = nil
        presentedCompletionAt = nil
        target.presentationChanged()
        ownedTasks.cancel(.snapshots)
        presentedRevision = 0
        showsRecentPresentation = false
    }

    private func showRecentPresentation(threadID: String) {
        guard let presentation = target.recentPresentation(threadID: threadID),
              renderedMessages.hasOpeningRendered(presentation.messages) else { return }
        messages = presentation.messages
        forkableMessageIDs = presentation.forkableMessageIDs
        streamItems = presentation.items
        renderedMessages.ensureRendered(presentation.messages)
        showsRecentPresentation = true
    }

    func observe(_ conversation: ConversationSession) {
        guard target.acceptsWork else { return }
        guard selectedConversation !== conversation || !ownedTasks.isRunning(.snapshots) else {
            target.presentationChanged()
            return
        }
        if activeSessionID == nil {
            conversation.rowPresentations.adopt(transcriptRowPresentations, readingPosition: conversation.readingPosition)
            conversation.readingPosition.record(isFollowingLatest: transcriptReadingPosition.isFollowingLatest,
                anchor: transcriptReadingPosition.anchor, mountedStartRowID: transcriptReadingPosition.mountedStartRowID)
        }
        transcriptReadingPosition = conversation.readingPosition
        transcriptRowPresentations = conversation.rowPresentations
        selectedConversation = conversation
        target.questionScopesChanged()
        target.presentationChanged()
        ownedTasks.start(.snapshots) { [weak self] in
            let snapshots = await conversation.snapshots()
            var isInitialSnapshot = true
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { return }
                if isInitialSnapshot {
                    self.target.questions.sessionBound(snapshot)
                    isInitialSnapshot = false
                }
                await self.publish(snapshot)
            }
        }
    }

    func publish(_ snapshot: ConversationSnapshot) async {
        guard admits(snapshot), let session = selectedConversation else { return }
        if snapshot.items.isEmpty, showsRecentPresentation {
            compaction = snapshot.compaction
            return
        }
        let preparationID = UUID()
        preparingRenderWindows[preparationID] = Set(snapshot.messages.map(\.id))
        target.retainPresentedRenders()
        defer {
            preparingRenderWindows.removeValue(forKey: preparationID)
            target.retainPresentedRenders()
        }
        if streamItems.isEmpty || showsRecentPresentation {
            await renderedMessages.prepareOpening(snapshot.messages)
        } else {
            await renderedMessages.prepareTail(snapshot.messages)
        }
        guard admits(snapshot) else { return }
        let span = PerfBuild.span("snapshot.apply")
        defer { span.end() }
        presentedRevision = snapshot.revision
        compaction = snapshot.compaction
        PerfBuild.count("publish")
        if snapshot.messages.contains(where: \.isStreaming) {
            Self.streamingMotionLogger.debug("publish revision=\(snapshot.revision)")
        }
        showsRecentPresentation = false
        messages = snapshot.messages
        forkableMessageIDs = snapshot.forkableMessageIDs
        streamItems = snapshot.items
        canPrefetchOlderHistory = snapshot.canPrefetchOlder
        renderedMessages.ensureRendered(snapshot.messages)
        presentedCompletionAt = snapshot.lastTurnCompletedAt
        publishSeenCompletion()
        pendingQuestion = snapshot.pendingQuestion
        questionPrompts = snapshot.questionPrompts
        target.recordPresented(snapshot, session: session)
    }

    private func admits(_ snapshot: ConversationSnapshot) -> Bool {
        guard target.acceptsWork else { return false }
        return snapshot.conversationID == currentConversationID && snapshot.ownerID == selectedConversation?.identity
            && snapshot.threadID == activeSessionID && snapshot.revision >= presentedRevision
    }

    var isOnScreen: Bool { presentation.presented && target.isSceneLive }

    func setPresentation(_ next: TargetPresentation) {
        guard target.acceptsWork, presentation != next else { return }
        let previous = presentation
        presentation = next
        if next.presented != previous.presented {
            target.retainPresentedRenders()
            if next.presented { renderedMessages.ensureRendered(messages) }
            presentedChanged(next.presented)
        }
        if next.drawerOpen != previous.drawerOpen { publishSeenCompletion() }
        if next.coversTranscript != previous.coversTranscript { historyEdges.setTranscriptCovered(next.coversTranscript) }
        target.screenPresentationChanged()
    }

    private func presentedChanged(_ presented: Bool) {
        if presented {
            dictation.refreshRecoverable()
        } else {
            headerNavigation.cancel()
            historyOpenSignpost.abandon(.cancelled)
            dictation.finishForHandOff()
        }
    }

    func publishSeenCompletion() {
        guard isOnScreen, !presentation.coversTranscript, let threadID = activeSessionID, let presentedCompletionAt else { return }
        let completion = SeenCompletion(threadID: threadID, completedAt: presentedCompletionAt)
        guard completion != markedCompletion else { return }
        markedCompletion = completion
        target.markCompletionSeen(threadID: threadID, completedAt: presentedCompletionAt)
    }

    // MARK: - Resume

    func recordTokenUsage(_ usage: CodexAppServerV2.ThreadTokenUsage?, threadID: String) {
        guard threadID == activeSessionID else { return }
        contextWindowUsage = usage.flatMap { ContextWindowUsage($0) }
    }

    func beginResumeLoad(threadID: String) -> UUID {
        contextWindowUsage = nil
        let loadID = UUID()
        resumeLoadID = loadID
        loadingTranscriptID = threadID
        return loadID
    }

    private func startResumeLoad(_ operation: @escaping @MainActor () async -> ResumeOutcome) {
        ownedTasks.start(.resume) { _ = await operation() }
    }

    func isCurrentResumeLoad(_ loadID: UUID, threadID: String) -> Bool {
        !Task.isCancelled && target.acceptsWork && resumeLoadID == loadID && activeSessionID == threadID
    }

    func finishResumeLoad() {
        loadingTranscriptID = nil
        resumeLoadID = nil
    }

    func cancelResumeLoad() {
        ownedTasks.cancel(.resume)
        finishResumeLoad()
    }

    // MARK: - Lifecycle

    func beginQuiescing() {
        ownedTasks.quiesce()
        headerNavigation.quiesce()
        historyEdges.quiesce()
        dictation.beginQuiescing()
    }

    func finishQuiescing() async -> String? {
        let dictationFailure = await dictation.finishQuiescing()
        await ownedTasks.drain()
        await headerNavigation.drain()
        await historyEdges.drain()
        return dictationFailure
    }

    func resumeAfterTermination() {
        ownedTasks.resume()
        headerNavigation.resume()
        historyEdges.resume()
        dictation.resumeAfterTermination()
        if let selectedConversation { observe(selectedConversation) }
        if let currentDraft { target.fileImports.resume(in: currentDraft) }
    }

    func retire() -> [Task<Void, Never>] {
        htmlVisualPreparation.cancelDemand()
        return ownedTasks.cancelAll() + headerNavigation.cancel() + historyEdges.cancelReads() + dictation.retire()
    }

    func close() {
        setPresentation(TargetPresentation())
        drafts.requestFlush()
        _ = retire()
        pendingSettings.removeAll()
        historyOpenSignpost.abandon(.cancelled)
        cancelResumeConversationLoad()
    }

    // MARK: - HistoryEdgeHost

    var historyReadTarget: HistoryEdgeReader.Target? {
        guard loadingTranscriptID == nil, let thread = activeConversation, thread.id == activeSessionID else { return nil }
        return .init(header: thread, transcriptIdentity: transcriptIdentity, conversationID: currentConversationID)
    }

    var endsAtNewerHistoryEdge: Bool { streamItems.endsAtNewerHistoryEdge }

    var loadedTurnCount: Int {
        streamItems.count(where: { if case .message(let message) = $0 { message.role == .user } else { false } })
    }

    func hasHistoryEdge(_ kind: HistoryEdge.Kind) -> Bool {
        streamItems.contains { if case .historyEdge(let edge) = $0 { edge.kind == kind } else { false } }
    }

    func presentsTranscript(_ identity: String) -> Bool {
        transcriptIdentity == identity
    }

    func prepareRenderedMessages() async {
        await renderedMessages.prepare(messages)
    }

    func historyReadFailed(_ message: String) {
        present(.conversation(message))
    }

    func applyConversationSnapshot(_ snapshot: GatewayHistoryService.ConversationSnapshot,
                                   read: ConversationState.HistoryRead, from owner: ConversationSession, source: String) async {
        let session = await conversations.session(conversationID: owner.conversationID, threadID: snapshot.header.id)
        guard target.acceptsWork, session.identity == owner.identity else { return }
        let result = await session.merge(snapshot, read: read)
        guard snapshot.header.id == activeSessionID, session.conversationID == currentConversationID,
              result.revision >= presentedRevision else { return }
        observe(session)
        activeConversation = snapshot.header
        adoptModelProvider(snapshot.header.modelProvider, threadID: snapshot.header.id)
        await publish(result)
        logger.notice("Conversation observation merged source=\(source, privacy: .public) revision=\(result.revision) messages=\(result.messages.count)")
    }

    // MARK: - Composer, send, resume and fork

    var recoverableDictations: [RecoverableDictation] { dictation.recoverable }

    var input: String {
        get { composerDocument?.content.expandedText ?? "" }
        set {
            guard target.acceptsWork, let draft = currentDraft else { return }
            drafts.setText(newValue, in: draft)
        }
    }

    var composerDocument: ComposerDocument? {
        currentDraft.map { drafts.document(for: $0) }
    }

    var composerControlInput: String { composerDocument?.controlText ?? "" }

    var composerAttachments: [ComposerAttachment] {
        get { currentDraft?.attachments ?? [] }
        set {
            guard target.acceptsWork, let draft = currentDraft else { return }
            drafts.setAttachments(newValue, in: draft)
        }
    }

    var fileUploads: [UUID: FileAttachmentImports.UploadState] { target.fileImports.uploads }

    var workingDirectory: String?

    var historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status] { historyEdges.status }

    /// A send waits for every file to reach the host: the prompt names paths
    /// the agent will read immediately. A file still copying into staging is
    /// not in the draft yet, so it is counted from the staging ledger.
    var hasUnfinishedFileUploads: Bool {
        return isStagingFiles || !composerAttachments.allSatisfy(\.isReadyToSend)
    }

    var isStagingFiles: Bool {
        currentDraft.map { target.fileImports.isStaging(draftID: $0.id) } ?? false
    }

    func draftMoveIssue(_ draft: ComposerDraft, toHost hostID: UUID) -> String? {
        if draft.document?.isComposing == true { return "Finish the current text input before moving this draft." }
        if target.fileImports.isStaging(draftID: draft.id) || !draft.attachments.allSatisfy(\.isReadyToSend) {
            return "Finish attaching files before moving this draft."
        }
        if hostID != self.hostID, draft.attachments.contains(where: { $0.file != nil }) {
            return "This host cannot access the files attached to this draft."
        }
        return nil
    }

    var composerSendState: ComposerSendState {
        let text = composerControlInput
        return composerSendState(input: text, command: ComposerSlashCommand.parse(text))
    }

    func composerSendState(input: String, command: ComposerSlashCommand.Input) -> ComposerSendState {
        if compaction?.blocksSending == true || composerDocument?.isComposing == true { return .blocked }
        switch command {
        case .command: return compactionUnavailableReason == nil ? .send : .blocked
        case .incomplete, .unsupported, .unexpectedArguments: return .blocked
        case .message: break
        }
        return ComposerSendState(
            input: input, hasAttachments: !composerAttachments.isEmpty,
            isPreparingAttachments: isStagingFiles,
            isWorking: isCurrentConversationBusy, canSteer: canSteerCurrentConversation,
            isBlocked: !areConversationSettingsReady || currentConversationDispatchBlock != nil
                || hasUnfinishedFileUploads || selectedModel == nil
        )
    }

    var hasDispatchableCurrentMessage: Bool {
        composerDocument?.hasContent == true || !composerAttachments.isEmpty
    }

    struct ResolvedDispatchMessage: Sendable {
        enum Content: Sendable {
            case composed(ComposerDocumentContent)
            case question(text: String, display: String)
        }
        let content: Content
        let fileAttachments: [UploadedFile]
    }

    private struct MessageSaveError: LocalizedError {
        let underlying: Error
        var errorDescription: String? { "Could not save the message: \(underlying.localizedDescription)" }
    }

    func send() async -> Bool {
        if ComposerSlashCommand.parse(composerControlInput) != .message { return await sendSlashCommand() }
        return await send(interactionMode: .text)
    }

    var canQueueCurrentMessage: Bool {
        composerSendState == .steer && currentAgentProvider == .codex
    }

    func queue() async -> Bool {
        let feedback = target.feedbackForCurrentConversation()
        guard target.acceptsWork, canQueueCurrentMessage, let threadID = activeSessionID, let draft = currentDraft else { return false }
        let resolved = resolvedMessageForDispatch()
        guard isDispatchable(resolved) else { return false }
        guard let admission = drafts.reserveSubmission(of: draft) else { return false }
        defer { drafts.releaseSubmission(admission) }
        do {
            try await enqueue(resolved, draft: draft, threadID: threadID)
        } catch {
            present(.draft(error.localizedDescription))
            if !(error is CancellationError) { feedback(.error) }
            return false
        }
        return true
    }

    private func enqueue(_ resolved: ResolvedDispatchMessage, draft: ComposerDraft, threadID: String) async throws {
        let feedback = target.feedbackForCurrentConversation()
        let conversationID = currentConversationID
        guard let outgoing = drafts.beginSending(draft) else { throw CancellationError() }
        var saved = false
        defer { if !saved { drafts.returnToComposer(outgoing) } }
        let prepared = await Self.prepareDispatch(resolved)
        let userMessage = ChatMessage(role: .user, text: prepared.body,
                                      attachments: prepared.attachments, inlineContent: prepared.inline)
        let session = await conversations.session(conversationID: conversationID, threadID: threadID)
        try Task.checkCancellation()
        guard target.acceptsWork else { throw CancellationError() }
        if currentConversationID == conversationID { observe(session) }
        do { await publish(try await session.submitToQueue(userMessage, input: prepared.text)) }
        catch { throw MessageSaveError(underlying: error) }
        try await committed(userMessage, in: session, conversationID: conversationID, feedback: feedback)
        do { try await session.persistSubmission(userMessage.id) }
        catch { throw MessageSaveError(underlying: error) }
        drafts.submitted(outgoing, conversationID: conversationID)
        saved = true
        try await requireDispatchAdmission(userMessage.id, in: session)
        if currentConversationID == conversationID { observe(session) }
        target.dispatcher.queue(messageID: userMessage.id, conversationID: conversationID, threadID: threadID,
                                input: prepared.text)
    }

    func sendQueuedMessageNow(_ message: ChatMessage) {
        guard target.acceptsWork, message.delivery == .queued, let threadID = activeSessionID,
              let model = selectedModel else { return }
        target.dispatcher.startQueued(messageID: message.id, conversationID: currentConversationID, threadID: threadID,
                                      settings: turnSettings(model: model))
    }

    func removeQueuedMessage(_ message: ChatMessage) {
        guard target.acceptsWork, message.delivery == .queued, let threadID = activeSessionID else { return }
        target.dispatcher.removeQueued(messageID: message.id, conversationID: currentConversationID, threadID: threadID)
    }

    private func committed(_ userMessage: ChatMessage, in session: ConversationSession, conversationID: UUID,
                           feedback: (HapticEvent) -> Void) async throws {
        try await requireDispatchAdmission(userMessage.id, in: session)
        feedback(.commit)
        if currentConversationID == conversationID, selectedConversation === session {
            historyEdges.showLatest()
            requestTranscriptRow(ChatStreamItem.message(userMessage).id, anchor: .top, motion: .animated)
        }
    }

    private func requireDispatchAdmission(_ messageID: UUID, in session: ConversationSession) async throws {
        guard !Task.isCancelled, target.acceptsWork else {
            await session.submissionFailed(messageID, failure: .notDispatched)
            throw CancellationError()
        }
    }

    var slashCommandSuggestions: [ComposerSlashCommand] { ComposerSlashCommand.suggestions(for: composerControlInput) }

    var slashCommandError: String? {
        slashCommandError(for: ComposerSlashCommand.parse(composerControlInput))
    }

    func slashCommandError(for command: ComposerSlashCommand.Input) -> String? {
        switch command {
        case .unsupported(let name): "Unknown command \(name). Type / to see available commands."
        case .unexpectedArguments(let command): "Use \(command.invocation) on its own."
        default: nil
        }
    }

    var compactionUnavailableReason: String? {
        guard target.acceptsWork, acceptsConversationInput else { return "This conversation cannot accept commands." }
        guard let threadID = activeSessionID, selectedConversation != nil else { return "Open an existing conversation to compact its context." }
        guard loadingTranscriptID == nil, areConversationSettingsReady else { return "Wait for the conversation to finish loading." }
        guard compaction?.blocksSending != true else { return "Wait for compaction to finish or refresh its status." }
        guard composerAttachments.isEmpty, !isStagingFiles else { return "Remove attachments before compacting." }
        guard currentConversationDispatchBlock == nil,
              target.conversationActivity.state(for: threadID, hasManagedTurn: isCurrentConversationBusy) == .idle else {
            return "Compaction is available when this conversation is confirmed idle."
        }
        return nil
    }

    func chooseSlashCommand(_ command: ComposerSlashCommand) { input = command.invocation }

    private func sendSlashCommand() async -> Bool {
        guard case .command(.compact) = ComposerSlashCommand.parse(composerControlInput) else {
            if let message = slashCommandError { present(.conversation(message)) }
            return false
        }
        if let reason = compactionUnavailableReason { present(.conversation(reason)); return false }
        guard let session = selectedConversation, let threadID = activeSessionID, let draft = currentDraft,
              !ownedTasks.isRunning(.compaction), let admission = drafts.reserveSubmission(of: draft) else { return false }
        defer { drafts.releaseSubmission(admission) }
        let revision = draft.revision
        let requestID = UUID()
        let provider = currentAgentProvider
        let exactTarget = target
        let exactGateway = target.gatewayClient
        let conversationID = currentConversationID
        guard await session.beginCompaction(requestID) else { return false }
        await publish(await session.snapshot())
        var acknowledged = false
        ownedTasks.start(.compaction) { [weak self] in
            guard let self else { return }
            do {
                guard !Task.isCancelled, exactTarget.acceptsWork, currentConversationID == conversationID,
                      activeSessionID == threadID, selectedConversation === session else {
                    await session.compactionRequestFailed(requestID, message: "Compaction was canceled before it started.", deliveryUncertain: false)
                    return
                }
                try await exactGateway.compactThread(threadID: threadID, provider: provider)
                acknowledged = true
                if target.acceptsWork, draft.revision == revision {
                    drafts.setText("", in: draft)
                    drafts.requestFlush()
                }
            } catch {
                let uncertain: Bool
                if let failure = error as? GatewayRPCFailure { uncertain = failure.kind == .compactionDeliveryUncertain }
                else if error is GatewayClient.CompactionPreparationFailure { uncertain = false }
                else if let clientError = error as? GatewayClient.ClientError, case .serverError = clientError { uncertain = false }
                else { uncertain = true }
                await session.compactionRequestFailed(requestID, message: error.localizedDescription, deliveryUncertain: uncertain)
            }
            await publish(await session.snapshot())
        }
        await ownedTasks.value(.compaction)
        return acknowledged
    }

    func refreshCompactionStatus() {
        guard !ownedTasks.isRunning(.compaction), !ownedTasks.isRunning(.compactionStatus),
              let session = selectedConversation, let threadID = activeSessionID,
              let current = compaction, current.blocksSending else { return }
        let exactTarget = target
        let exactGateway = target.gatewayClient
        let conversationID = currentConversationID
        ownedTasks.start(.compactionStatus) { [weak self] in
            guard let self, let read = historyEdges.reloadTail() else { return }
            await read.value
            guard !Task.isCancelled, exactTarget.acceptsWork, selectedConversation === session,
                  currentConversationID == conversationID, activeSessionID == threadID,
                  historyEdges.status[.newer] != .failed else { return }
            do {
                let observedAt = Date.now
                let snapshot = try await exactGateway.readActiveTurns()
                guard !Task.isCancelled, exactTarget.acceptsWork, selectedConversation === session,
                      currentConversationID == conversationID, activeSessionID == threadID,
                      compaction?.requestID == current.requestID, !ownedTasks.isRunning(.compaction) else { return }
                exactTarget.applyActivity(snapshot, observedAt: observedAt)
                let fresh = ConversationActivity(snapshot: snapshot)
                guard snapshot.canConfirmInactivity(for: threadID), fresh.state(for: threadID) == .idle,
                      fresh.dispatchBlock(for: threadID) == nil else { return }
                await session.compactionIdleConfirmed(requestID: current.requestID, turnID: current.turnID)
                await publish(await session.snapshot())
            } catch {
                guard !Task.isCancelled, exactTarget.acceptsWork, selectedConversation === session else { return }
                present(.conversation("Could not refresh compaction status: \(error.localizedDescription)"))
            }
        }
    }

    private func send(interactionMode: CodexInteractionMode) async -> Bool {
        let feedback = target.feedbackForCurrentConversation()
        guard target.acceptsWork, acceptsConversationInput, composerSendState.canSend, let draft = currentDraft else { return false }
        let resolved = resolvedMessageForDispatch()
        guard isDispatchable(resolved) else { return false }
        guard let admission = drafts.reserveSubmission(of: draft) else { return false }
        defer { drafts.releaseSubmission(admission) }
        do {
            try await dispatch(resolved, draft: draft, questionReplies: nil,
                               interactionMode: interactionMode)
        } catch {
            present(.draft(error.localizedDescription))
            if !(error is CancellationError) { feedback(.error) }
            return false
        }
        return true
    }

    /// Shows the local user row at once, saves it, then hands the message to
    /// the running turn or a new turn. Question replies preserve the composer draft.
    @discardableResult
    func dispatch(_ resolved: ResolvedDispatchMessage, draft: ComposerDraft,
                  questionReplies: [QuestionReply]?,
                  interactionMode: CodexInteractionMode, expectedQuestionVersion: QuestionVersion? = nil) async throws -> UUID {
        let started = ContinuousClock.now
        refreshReasoningVisibility()
        let settings = try turnSettings()
        let feedback = target.feedbackForCurrentConversation()
        let conversationID = currentConversationID
        let sessionID = activeSessionID
        let activeTurn = sessionID.flatMap { target.turns.turn(forThread: $0) }
        // A send that lands in an already-running turn is a steer, not a new turn.
        let isSteering = activeTurn != nil
        var outgoing: ComposerDraftStore.OutgoingMessage?
        if questionReplies == nil {
            guard let message = drafts.beginSending(draft) else { throw CancellationError() }
            outgoing = message
            composerSends += 1
        }
        var saved = false
        defer { if !saved, let outgoing { drafts.returnToComposer(outgoing) } }
        let prepared = await Self.prepareDispatch(resolved)
        let userMessage = ChatMessage(
            role: .user,
            text: prepared.body,
            attachments: prepared.attachments,
            inlineContent: prepared.inline,
            wasSteered: isSteering,
            canonicalTurnID: isSteering ? activeTurn?.turnID : nil,
            questionReplies: questionReplies
        )
        let session = await conversations.session(conversationID: conversationID, threadID: sessionID)
        try Task.checkCancellation()
        guard target.acceptsWork else { throw CancellationError() }
        if currentConversationID == conversationID { observe(session) }
        do { await publish(try await session.submit(userMessage, input: prepared.text, expectedQuestionVersion: expectedQuestionVersion)) }
        catch { throw MessageSaveError(underlying: error) }
        let shown = ContinuousClock.now
        try await committed(userMessage, in: session, conversationID: conversationID, feedback: feedback)
        do { try await session.persistSubmission(userMessage.id) }
        catch { throw MessageSaveError(underlying: error) }
        if let outgoing { drafts.submitted(outgoing, conversationID: conversationID) }
        saved = true
        logger.notice("send shown=\(String(describing: started.duration(to: shown)), privacy: .public) saved=\(String(describing: started.duration(to: .now)), privacy: .public) steer=\(isSteering, privacy: .public)")
        try await requireDispatchAdmission(userMessage.id, in: session)
        if currentConversationID == conversationID { observe(session) }

        let submission = TurnDispatcher.Submission(
            draft: draft, conversationID: conversationID, userMessageID: userMessage.id, input: prepared.text,
            interactionMode: interactionMode, settings: settings)
        if let activeTurn {
            target.dispatcher.steer(submission, activeTurn: activeTurn)
        } else {
            target.dispatcher.startTurn(submission, sessionID: sessionID)
        }
        return userMessage.id
    }

    private func turnSettings() throws -> TurnDispatcher.Settings {
        guard let model = selectedModel else { throw ModelSelectionError.noModelToSend }
        return turnSettings(model: model)
    }

    private func turnSettings(model: ModelOption) -> TurnDispatcher.Settings {
        TurnDispatcher.Settings(model: model, reasoning: reasoningSelection,
                                serviceTier: serviceTierOverride, fastModeState: fastModeState,
                                workingDirectory: workingDirectory, selectionRevision: settingsSelectionRevision)
    }

    private func resolvedMessageForDispatch() -> ResolvedDispatchMessage {
        let files = composerAttachments.compactMap { $0.file?.uploaded }
        return ResolvedDispatchMessage(content: .composed(composerDocument?.content ?? .init(runs: [])),
                                      fileAttachments: files)
    }

    @concurrent
    private static func prepareDispatch(_ resolved: ResolvedDispatchMessage) async -> (text: String, body: String, attachments: [MessageAttachment], inline: InlineMessageContent?) {
        let prompt: String
        let body: String
        let pasted: [MessageAttachment]
        let inline: InlineMessageContent?
        switch resolved.content {
        case .composed(let content):
            prompt = content.prompt
            body = content.runs.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
            pasted = content.pasted.map { MessageAttachment(id: $0.id, content: .text($0.text)) }
            inline = pasted.isEmpty ? nil : InlineMessageContent(content)
        case .question(let text, let display):
            prompt = text
            body = display
            pasted = []
            inline = nil
        }
        let text = AttachedFilesPromptBlock.append(to: prompt, paths: resolved.fileAttachments.map(\.path))
        let attachments = pasted + resolved.fileAttachments.map {
                MessageAttachment(id: ChatMessage.deterministicID(for: "file:\($0.path)"), content: .file($0))
            }
        return (text, body, attachments, inline)
    }

    private func isDispatchable(_ resolved: ResolvedDispatchMessage) -> Bool {
        let hasText: Bool
        switch resolved.content {
        case .composed(let content):
            hasText = content.runs.contains {
                switch $0 {
                case .text(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .paste: true
                }
            }
        case .question(let text, _): hasText = !text.isEmpty
        }
        return hasText || !resolved.fileAttachments.isEmpty
    }

    func stopTurn(_ turn: RunningTurn) {
        guard target.acceptsWork, composerStopState == .ready(turn) else { return }
        let feedback = target.feedbackForCurrentConversation()
        let followUp = currentDraft.flatMap { draft in
            selectedModel.map { TurnDispatcher.FollowUp(conversationID: currentConversationID, draft: draft,
                                                        settings: turnSettings(model: $0)) }
        }
        target.dispatcher.stop(turn, followUp: followUp, feedback: feedback)
    }

    @discardableResult
    func openConversation(threadID: String) -> Task<Void, Never> {
        target.onConversationNavigation?()
        let gateway = target.gatewayClient
        return headerNavigation.open(threadID: threadID, read: {
            let response = try await gateway.readThread(threadID: $0, includeTurns: false)
            return await ConversationHeader.prepare(response.thread)
        }, present: { [weak self] in self?.resumeConversation($0) },
            failed: { [weak self] in self?.present(.conversation($0.localizedDescription)) })
    }

    func cancelPendingConversationOpen() {
        headerNavigation.cancel()
    }

    func resumeConversation(_ thread: ConversationHeader) {
        headerNavigation.cancel()
        let span = PerfBuild.span("switch.resume"); defer { span.end() }
        target.onConversationNavigation?()
        let identity = "\(executionTarget.id)|\(thread.id)"
        if transcriptIdentity != identity { historyOpenSignpost.begin() }
        dictation.finishForHandOff()
        selectDraft(.thread(thread.id))
        resumeStagedUploads()
        historyEdges.reset()
        cancelResumeConversationLoad()
        dismissAlert()
        activeConversation = thread
        setActiveSessionID(thread.id)
        adoptModelProvider(thread.modelProvider, threadID: thread.id)
        showRecentSettings(threadID: thread.id)
        if transcriptIdentity != identity { showTranscript(identity: identity, threadID: thread.id) }
        let loadID = beginResumeLoad(threadID: thread.id)
        if !thread.cwd.isEmpty { updateWorkingDirectory(thread.cwd) }
        let settingsRevision = settingsSelectionRevision
        startResumeLoad { [weak self] in
            guard let self else { return .superseded }
            #if os(macOS) && RC_PERF_HARNESS
            if let fixture = self.target.switchFixtures[thread.id] {
                await self.adopt(fixture.session)
                guard self.isCurrentResumeLoad(loadID, threadID: thread.id) else { return .superseded }
                do {
                    try await fixture.session.restore()
                    await self.publish(await fixture.session.snapshot())
                    guard self.isCurrentResumeLoad(loadID, threadID: thread.id) else { return .superseded }
                    self.finishResumeLoad()
                    return .loaded
                } catch { return .failed(error) }
            }
            #endif
            let id = await self.target.sessionIndex.conversationID(for: thread.id) ?? ChatMessage.deterministicID(for: thread.id)
            let previous = await self.target.conversationWarmer.prepareOpening(threadID: thread.id)
            guard !Task.isCancelled, self.isCurrentResumeLoad(loadID, threadID: thread.id) else { return .superseded }
            let session = await self.conversations.session(conversationID: id, threadID: thread.id)
            guard self.isCurrentResumeLoad(loadID, threadID: thread.id) else { return .superseded }
            if previous !== session { self.target.conversationWarmer.invalidate(thread.id) }
            await self.adopt(session)
            guard self.isCurrentResumeLoad(loadID, threadID: thread.id) else { return .superseded }
            return await self.loadResumeConversation(thread, session: session, previousOwner: previous,
                loadID: loadID, settingsRevision: settingsRevision)
        }
    }

    private func loadResumeConversation(_ thread: ConversationHeader, session: ConversationSession, previousOwner: ConversationSession?,
                                        loadID: UUID, settingsRevision: UInt64) async -> ResumeOutcome {
        let operation = AppPerformanceDiagnostics.shared.beginHistory(.opening, threadID: thread.id)
        async let settings: Void = restoreConversationSettings(thread, loadID: loadID, revision: settingsRevision)
        var failure: (any Error)?
        do {
            try await session.restore()
            if previousOwner !== session, thread.id.hasPrefix("claude_") {
                await target.replayOpenedClaudeThread(threadID: thread.id, owner: session)
                guard isCurrentResumeLoad(loadID, threadID: thread.id) else { throw CancellationError() }
            }
            await publish(await session.snapshot())
            let stored = await session.beginHistoryRead()
            if let cached = await historyService.cachedConversation(header: thread) {
                await applyConversationSnapshot(cached, read: stored, from: session, source: "disk")
            }
            let observed = target.conversationWarmer.observation(threadID: thread.id, revision: thread.updatedAt)
            let read = await session.beginHistoryRead()
            let snapshot = try await historyService.openTail(header: thread, base: read.base,
                bypassCache: target.conversationWarmer.needsRead(threadID: thread.id, revision: thread.updatedAt))
            await applyConversationSnapshot(snapshot, read: read, from: session, source: "network")
            target.dispatcher.reconcileQueue(threadID: thread.id)
            target.conversationWarmer.readSucceeded(threadID: thread.id, observation: observed)
            if isCurrentResumeLoad(loadID, threadID: thread.id), contextWindowUsage == nil {
                recordTokenUsage(await session.validTokenUsage(), threadID: thread.id)
            }
            await target.sessionIndex.record(sessionID: thread.id, conversationID: session.conversationID)
        } catch {
            if isCurrentResumeLoad(loadID, threadID: thread.id) {
                if !GatewayHistoryService.defersRead(error) { present(.conversation(error.localizedDescription)) }
                failure = error
            }
        }
        await settings
        guard isCurrentResumeLoad(loadID, threadID: thread.id) else {
            AppPerformanceDiagnostics.shared.finishHistory(operationID: operation)
            return .superseded
        }
        finishResumeLoad()
        target.synchronizeConversationActivity()
        if failure != nil { historyEdges.retainFailedOpening() }
        else { historyEdges.prefetchEarlier() }
        if messages.isEmpty { historyOpenSignpost.abandon(failure == nil ? .empty : .failed) }
        AppPerformanceDiagnostics.shared.finishHistory(operationID: operation)
        await conversations.evictIdle(keeping: target.presentedConversationIDs)
        target.warmConversationsIfIdle()
        return failure.map(ResumeOutcome.failed) ?? .loaded
    }

    func forkConversation(_ thread: ConversationHeader) async {
        await fork(threadID: thread.id, lastTurnID: nil, serviceTier: forkServiceTier(for: thread.id))
    }

    func forkServiceTier(for threadID: String) -> CodexAppServerV2.ServiceTierOverride? {
        threadID == activeSessionID ? serviceTierOverride : nil
    }

    func forkConversation(from message: ChatMessage) async {
        guard forkableMessageIDs.contains(message.id), let sessionID = activeSessionID else { return }
        guard let turnID = message.canonicalTurnID else {
            present(.conversation("This message's canonical turn is not loaded yet. Reload its history before forking."))
            return
        }
        await fork(threadID: sessionID, lastTurnID: turnID, serviceTier: serviceTierOverride)
    }

    private func fork(threadID: String, lastTurnID: String?,
                      serviceTier: CodexAppServerV2.ServiceTierOverride?) async {
        let feedback = target.feedbackForCurrentConversation()
        do {
            let response = try await target.gatewayClient.forkThread(threadID: threadID, lastTurnID: lastTurnID, serviceTier: serviceTier)
            if AgentProvider.provider(forThreadID: response.thread.id) == .claude {
                await target.metadataService.sync()
            }
            feedback(.success)
            resumeConversation(await ConversationHeader.prepare(response.thread))
        } catch {
            present(.conversation(error.localizedDescription))
            if !(error is CancellationError) { feedback(.error) }
        }
    }

    var newChatDestination: ComposerDraftStore.Destination { .newChat(newChatDraftID) }

    var shownNewChatDraft: UUID? {
        guard openThreadID == nil, draftDestination == newChatDestination,
              currentDraft.map({ $0.destination == newChatDestination.key }) ?? true else { return nil }
        return newChatDraftID
    }

    var showsUnsentContent: Bool {
        shownNewChatDraft != nil && currentDraft.map(drafts.hasContent) == true
    }

    func startNewConversation() {
        let shown = drafts.cachedDraft(for: newChatDestination)
        let isOccupied = shown.map(drafts.hasContent) ?? drafts.unsentDrafts.contains { $0.id == newChatDraftID }
        if isOccupied || target.voice.isRecording || target.voice.isTranscribing {
            newChatDraftID = UUID()
        }
        showNewChatDraft()
    }

    func releaseNewChatDraft() {
        let wasShown = shownNewChatDraft != nil
        newChatDraftID = UUID()
        if wasShown { showNewChatDraft() }
    }

    func openUnsentDraft(_ id: UUID) {
        guard shownNewChatDraft != id else { return }
        newChatDraftID = id
        showNewChatDraft()
    }

    func suggestWorkingDirectory(_ path: String) {
        guard shownNewChatDraft != nil, !showsUnsentContent else { return }
        updateWorkingDirectory(path)
        recordNewChatSetup()
    }

    private func showNewChatDraft() {
        headerNavigation.cancel()
        target.onConversationNavigation?()
        dictation.finishForHandOff()
        selectDraft(newChatDestination)
        resumeStagedUploads()
        historyEdges.reset()
        historyOpenSignpost.abandon(.cancelled)

        logger.info("clear chat start summary=\(self.debugChatStateSummary(), privacy: .public)")
        cancelResumeConversationLoad()
        dismissAlert()

        beginNewChat()
        if let draft = currentDraft, draft.newChat != nil { adoptSetup(of: draft) } else { refreshNewChatDefaults() }
        resetRendering()
        logger.info("clear chat complete summary=\(self.debugChatStateSummary(), privacy: .public)")
    }

    private var newChatSetup: NewChatSetup {
        let modelID: String? = if let selectedModel { selectedModel.id }
            else if case .unavailable(let modelID, _) = newChatModelSource { modelID } else { nil }
        return NewChatSetup(workingDirectory: workingDirectory, modelID: modelID, reasoning: reasoningSelection,
                            fastMode: fastModeSelection)
    }

    private func chooseNewChatSetup() {
        setupChoices &+= 1
        recordNewChatSetup()
    }

    private func recordNewChatSetup() {
        guard activeSessionID == nil, let draft = currentDraft,
              ComposerDraftStore.Destination.isNewChat(key: draft.destination) else { return }
        drafts.setNewChatSetup(newChatSetup, in: draft)
    }

    private func recordBlankNewChatSetup() {
        if !showsUnsentContent { recordNewChatSetup() }
    }

    private func adoptSetup(of draft: ComposerDraft) {
        guard activeSessionID == nil else { return }
        if let setup = draft.newChat {
            if setup != newChatSetup { applyNewChatSetup(setup) }
        } else {
            recordNewChatSetup()
        }
    }

    private func applyNewChatSetup(_ setup: NewChatSetup) {
        if let directory = setup.workingDirectory { updateWorkingDirectory(directory) }
        guard let modelID = setup.modelID else { return refreshNewChatDefaults() }
        guard !adoptSettings(modelID: modelID, reasoning: setup.reasoningSelection ?? reasoningSelection,
                             fastModeState: .selection(setup.fastMode), source: .draftSetup) else { return }
        if case .unavailable(let unavailable, _) = newChatModelSource, unavailable == modelID { return }
        refreshNewChatDefaults()
    }

    /// Called by the transcript when it appears and when message rows scroll
    /// into view; closes a pending chat-open interval.
    func markTranscriptFirstAppear() {
        guard !messages.isEmpty else { return }
        historyOpenSignpost.contentVisible()
    }

    func toggleTimeline(jobID: String) {
        guard let session = selectedConversation else { return }
        Task { await session.toggleGroup(jobID) }
    }

    func debugChatStateSummary() -> String {
        let activeSession = activeSessionID ?? "nil"
        let activeConversationID = activeConversation?.id ?? "nil"
        let loading = loadingTranscriptID ?? "nil"
        let activeTurns = target.turns.trackedThreadIDs.sorted().joined(separator: ",")
        return "conversation=\(currentConversationID.uuidString) activeSession=\(activeSession) activeConversation=\(activeConversationID) loading=\(loading) messages=\(messages.count) jobs=\(target.turns.jobs.count) activeTurns=[\(activeTurns)] dispatchedTurns=\(target.turns.dispatchedTurns.count)"
    }

    func micTapStart() {
        guard target.directories.information?.speechAvailable != false else {
            target.voiceError = "Speech is not configured on this gateway."
            target.feedbackForCurrentConversation()(.error)
            return
        }
        dictation.beginCapture(into: currentDraft)
    }

    func micTapStartAsync() async {
        guard target.directories.information?.speechAvailable != false else {
            target.voiceError = "Speech is not configured on this gateway."
            target.feedbackForCurrentConversation()(.error)
            return
        }
        let feedback = target.feedbackForCurrentConversation()
        do {
            try await target.voice.startAsync()
        } catch {
            guard !(error is CancellationError) else { return }
            target.voiceError = error.localizedDescription
            feedback(.error)
        }
    }

    func micTapStopImmediate() {
        target.voice.markStopRequested()
    }

    func micTapStopAsync() async {
        await dictation.finish(feedback: target.feedbackForCurrentConversation())
    }

    func transcribeRecoverableDictation(_ id: UUID) {
        guard target.acceptsWork, let draft = currentDraft else { return }
        dictation.transcribe(id, into: draft, feedback: target.feedbackForCurrentConversation())
    }

    func deleteRecoverableDictation(_ id: UUID) {
        dictation.delete(id, feedback: target.feedbackForCurrentConversation())
    }

    func updatePastedText(_ text: String, attachmentID: UUID, in draft: ComposerDraft) {
        guard target.acceptsWork else { return }
        drafts.updatePastedText(text, attachmentID: attachmentID, in: draft)
    }

    func removeAttachment(_ attachment: ComposerAttachment) {
        guard composerAttachments.contains(where: { $0.id == attachment.id }) else { return }
        if attachment.text == nil {
            target.fileImports.remove(attachment)
        }
        composerAttachments.removeAll { $0.id == attachment.id }
        target.feedbackForCurrentConversation()(.commit)
    }

    func handlePickedMedia(_ items: [PhotosPickerItem], for draft: ComposerDraft) {
        importFiles(items.map(DeferredImportFile.photo), for: draft)
    }

    func handlePastedImages(_ images: [PastedImage], for draft: ComposerDraft) {
        importFiles(images.map { image in .inOwnDirectory { try await AgentImageFiles.write(image) } }, for: draft)
    }

    func importFiles(_ files: [DeferredImportFile], for draft: ComposerDraft) {
        guard target.acceptsWork, !files.isEmpty else { return }
        let batch = AttachmentFeedbackBatch(count: files.count, feedback: attachmentFeedback(for: draft))
        target.fileImports.add(files, to: draft, onStaged: batch.finish, onUploadFailure: batch.uploadFailed)
    }

    func attachmentFeedback(for draft: ComposerDraft) -> (HapticEvent) -> Void {
        let feedback = target.feedbackForCurrentConversation()
        let isCurrentDraft = currentDraft === draft
        return { [weak self, weak draft] event in
            guard let self, let draft, isCurrentDraft, self.currentDraft === draft else { return }
            feedback(event)
        }
    }

    func handlePickedFiles(_ urls: [URL], for draft: ComposerDraft) {
        importFiles(urls.map { url in .borrowed { url } }, for: draft)
    }

    func receiveSharedItems(_ id: UUID) {
        guard target.acceptsWork else { return }
        let destination = draftDestination
        ownedTasks.start(.sharedItems(id)) { [weak self] in
            guard let self, await self.prepareDraft(destination), let draft = self.currentDraft else { return }
            await self.updateWorkingDirectoryToRemoteHome(preferCachedHomePath: true)
            guard !Task.isCancelled else { return }
            do {
                guard let inbox = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: RemoteCoderAppGroup.identifier)
                    .map(SharedItemsInbox.init(appGroupContainer:)) else { throw SharedItemsInbox.Unavailable() }
                self.attach(try await inbox.claim(id, into: FileManager.default.temporaryDirectory.appending(path: "SharedItems")), to: draft)
            } catch {
                self.present(.attachments("Could not add the shared items: \(error.localizedDescription)"))
            }
        }
    }

    #if os(iOS)
    func receiveLockedCameraCaptures() {
        guard target.acceptsWork else { return }
        let destination = draftDestination
        ownedTasks.start(.cameraCaptures) { [weak self] in
            guard let self else { return }
            do {
                guard await self.prepareDraft(destination), let draft = self.currentDraft else { return }
                await self.updateWorkingDirectoryToRemoteHome(preferCachedHomePath: true)
                try Task.checkCancellation()
                try await LockedCameraCaptureImports.shared.receive { [weak self] files in
                    guard let self, self.target.acceptsWork, !Task.isCancelled,
                          self.draftDestination == destination else { throw CancellationError() }
                    self.importFiles(files.map { file in .inOwnDirectory { file } }, for: draft)
                }
            } catch is CancellationError {
            } catch {
                self.present(.attachments("Could not add the captured photo: \(error.localizedDescription)"))
            }
        }
    }

    func openCamera(present: @escaping @MainActor (ComposerDraft) -> Void) {
        let destination = draftDestination
        ownedTasks.start(.cameraCaptures) { [weak self] in
            guard let self, await self.prepareDraft(destination), let draft = self.currentDraft else { return }
            await self.updateWorkingDirectoryToRemoteHome(preferCachedHomePath: true)
            guard !Task.isCancelled, self.target.acceptsWork, self.draftDestination == destination else { return }
            present(draft)
        }
    }
    #endif

    private func attach(_ claim: SharedItemsInbox.Claim, to draft: ComposerDraft) {
        guard target.acceptsWork else { return }
        importFiles(claim.files.map { file in .inOwnDirectory { file } }, for: draft)
        switch ComposerPastedText(claim.text.joined(separator: "\n")) {
        case .attachment(let text): drafts.setAttachments(draft.attachments + [.text(text)], in: draft)
        case .inline(let text): drafts.document(for: draft).edit(.insert(.init(runs: [.text(text)])))
        case nil: break
        }
    }

    func retryUpload(_ attachmentID: UUID) {
        guard target.acceptsWork, let draft = currentDraft,
              let attachment = draft.attachments.first(where: { $0.id == attachmentID }) else { return }
        let feedback = attachmentFeedback(for: draft)
        target.fileImports.retry(attachment, in: draft, onUploadFailure: { feedback(.error) })
    }

    func resumeStagedUploads() {
        guard target.acceptsWork, let draft = currentDraft else { return }
        target.fileImports.resume(in: draft)
    }

    func handlePasteFromClipboard(_ paste: ComposerPaste<PastedImage>) -> Bool {
        guard target.acceptsWork else { return false }
        let attached = attachPastedContent(paste)
        if let text = paste.inlineText { composerDocument?.edit(.insert(.init(runs: [.text(text)]))) }
        return attached
    }

    func attachPastedContent(_ paste: ComposerPaste<PastedImage>) -> Bool {
        guard target.acceptsWork, let draft = currentDraft else { return false }
        if !paste.fileURLs.isEmpty { handlePickedFiles(paste.fileURLs, for: draft) }
        handlePastedImages(paste.images, for: draft)
        if case .attachment(let text) = paste.text { composerAttachments.append(.text(text)) }
        return paste.hasAttachments
    }

    func updateWorkingDirectory(_ path: String) {
        workingDirectory = path
        HostPreferences.setWorkingDirectory(path, hostID: hostID, defaults: target.chatDefaults)
    }

    func selectWorkingDirectory(_ path: String, ifStillShowing contextID: UUID) {
        guard currentConversationID == contextID else { return }
        selectWorkingDirectory(path)
    }

    func selectWorkingDirectory(_ path: String) {
        let selectedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedPath.isEmpty == false else { return }

        let currentPath = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let didChangeDirectory = currentPath != selectedPath

        if didChangeDirectory, shownNewChatDraft == nil {
            startNewConversation()
        }
        updateWorkingDirectory(selectedPath)
        chooseNewChatSetup()
    }

    func prepareVoiceModeWorkingDirectory(startsFreshChat: Bool) async {
        guard !target.realtimeVoice.isActive else { return }
        if startsFreshChat || workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            await updateWorkingDirectoryToRemoteHome(preferCachedHomePath: startsFreshChat)
        }
    }

    func updateWorkingDirectoryToRemoteHome(preferCachedHomePath: Bool = false) async {
        let conversationID = currentConversationID
        if preferCachedHomePath, let known = target.remoteHomePath {
            updateWorkingDirectory(known)
            recordBlankNewChatSetup()
            return
        }
        target.directories.startIfNeeded()
        guard let resolved = try? await target.directories.resolveHomePath(),
              currentConversationID == conversationID, isRetired == false else { return }
        updateWorkingDirectory(resolved)
        recordBlankNewChatSetup()
    }

    /// A host the user has never picked a directory for gets its own remote home,
    /// not another machine's repository path: the picker used to disappear
    /// entirely when this stayed nil, which made Claude dispatch impossible.
    func adoptRemoteHomeAsWorkingDirectoryIfUnset() {
        guard isRetired == false else { return }
        guard workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }
        guard let home = target.remoteHomePath else { return }
        updateWorkingDirectory(home)
        recordBlankNewChatSetup()
    }

    func openFileURL(_ url: URL, transition: HostFileTransition?, presentationScope: UUID?) -> OpenURLAction.Result {
        guard let origin = fileOrigin(presentationScope: presentationScope) else { return .discarded }
        return fileOpener.open(url, origin: origin, relativeTo: workingDirectory, transition: transition)
    }

    func openEmbeddedFile(_ file: EmbeddedFileRequest, frame: HostFileTransition.Frame?, presentationScope: UUID?) {
        guard let origin = fileOrigin(presentationScope: presentationScope) else { return }
        fileOpener.open(file, origin: origin, frame: frame)
    }

    private func fileOrigin(presentationScope: UUID?) -> HostFileOrigin? {
        guard target.acceptsWork, presentation.presented else { return nil }
        return HostFileOrigin(hostID: hostID,
            conversationID: currentConversationID, transcriptID: transcriptIdentity,
            workingDirectory: workingDirectory, hostName: target.hostDisplayName, presentationScope: presentationScope)
    }

    var htmlVisualDocuments: HTMLVisualDocumentStore { target.hostServices.htmlVisualDocuments }
    var htmlVisualRenderer: HTMLVisualRenderer { target.hostServices.htmlVisualRenderer }

    var imagePreviews: HostImagePreviews { target.hostServices.imagePreviews }

    func imagePreviewReference(for url: URL) -> HostFileReference? {
        guard let reference = try? HostFileReference.resolve(url: url, hostID: hostID, relativeTo: workingDirectory),
              HostImagePreviews.canPreview(reference) else { return nil }
        return reference
    }

    func cancelResumeConversationLoad() {
        cancelResumeLoad()
        pickerSelection.markReady()
    }

    // MARK: - Derived conversation state

    var isCurrentConversationBusy: Bool {
        target.turns.isBusy(conversationID: currentConversationID, threadID: activeSessionID)
    }

    enum ReplyDelivery: Sendable {
        case idle, pending, acknowledged
    }

    var currentReplyDelivery: ReplyDelivery {
        guard isCurrentConversationBusy else { return .idle }
        guard let sessionID = activeSessionID, target.turns.turn(forThread: sessionID) != nil,
              !target.turns.isSteering(threadID: sessionID) else { return .pending }
        return .acknowledged
    }

    var currentConversationActivity: CodexGatewayDaemon.ActivityState? {
        if let id = activeSessionID {
            let state = target.conversationActivity.state(for: id, hasManagedTurn: isCurrentConversationBusy)
            return state == .idle ? nil : state
        }
        return isCurrentConversationBusy ? .working : nil
    }

    var currentConversationChildren: Set<String> {
        activeSessionID.map(target.conversationActivity.childThreadIDs(of:)) ?? []
    }

    var currentConversationDispatchBlock: ConversationActivity.DispatchBlock? {
        return target.conversationActivity.dispatchBlock(for: activeSessionID, hasManagedTurn: canSteerCurrentConversation)
    }

    var isTakingOverCurrentConversation: Bool {
        guard let takeOver = target.takeOver else { return false }
        return takeOver.threadID == activeSessionID && takeOver.failure == nil
    }

    var takeOverFailure: String? {
        guard let takeOver = target.takeOver, takeOver.threadID == activeSessionID else { return nil }
        return takeOver.failure
    }

    func takeOverCurrentConversation() {
        guard target.acceptsWork, let sessionID = activeSessionID, currentConversationDispatchBlock == .otherClient else { return }
        target.takeOverConversation(threadID: sessionID)
    }

    var acceptsConversationInput: Bool { drafts.acceptsInput && activeConversation?.acceptsDirectInput != false }

    var acceptsAttachments: Bool {
        target.acceptsWork && currentDraft != nil && acceptsConversationInput && currentConversationDispatchBlock != .otherClient
    }

    var canSteerCurrentConversation: Bool {
        acceptsConversationInput && activeSessionID.flatMap { target.turns.turn(forThread: $0) } != nil
    }

    var runningTurn: RunningTurn? {
        activeSessionID.flatMap { threadID in
            target.turns.turn(forThread: threadID).map { RunningTurn(threadID: $0.threadID, turnID: $0.turnID) }
                ?? (compaction?.isActive == true ? compaction?.turnID.map { RunningTurn(threadID: threadID, turnID: $0) } : nil)
        }
    }

    var composerStopState: ComposerStopState {
        guard acceptsConversationInput, let turn = runningTurn else { return .hidden }
        return ComposerStopState(runningTurn: turn, isStopping: target.turnStops.isStopping(turn))
    }

    var stopFailure: String? {
        guard let failure = target.turnStops.failure, failure.threadID == activeSessionID else { return nil }
        return failure.message
    }

    // MARK: - Conversation settings

    var pickerSelection: ConversationSettingsSelection

    var settingsSelectionRevision: UInt64 { pickerSelection.revision }

    var isLoadingConversationSettings: Bool { pickerSelection.isLoading }

    var areConversationSettingsReady: Bool { pickerSelection.isReady }

    var pendingSettings: [String: ConversationSettingsUpdate] = [:]

    private var settingsDeferredUntilTurn: [String: String] = [:]

    private enum SettingsFeedback {
        case failure(String)
        case deferred(String)
    }

    private var settingsFeedback: [String: SettingsFeedback] = [:]

    var selectedModel: ModelOption? { pickerSelection.model }

    private enum NewChatModelSource {
        case resolvedDefault(AgentProvider?)
        case chosen
        case unavailable(modelID: String, lookup: NewChatModelLookup)
    }

    @ObservationIgnored private var newChatModelSource = NewChatModelSource.resolvedDefault(nil)

    private var requestedNewChatProvider: AgentProvider? {
        switch newChatModelSource {
        case .resolvedDefault(let provider): provider
        case .chosen: nil
        case .unavailable(let modelID, _): AgentProvider.provider(forModelID: modelID)
        }
    }

    var reasoningSelection: ReasoningSelection { pickerSelection.reasoning }

    var fastModeState: FastModeState { pickerSelection.fastMode }

    var fastModeSelection: Bool? { pickerSelection.fastModeSelection }

    var fastModeEnabled: Bool { fastModeSelection == true && selectedModel?.supportsFastMode == true }

    var currentAgentProvider: AgentProvider {
        activeSessionID.map(AgentProvider.provider(forThreadID:)) ?? selectedModel?.provider ?? .codex
    }

    var newChatModelUnavailableReason: String? {
        guard activeSessionID == nil, selectedModel == nil else { return nil }
        if case .unavailable(let modelID, let lookup) = newChatModelSource {
            switch lookup {
            case .notOffered: return "This host doesn't offer \(modelID). Choose another model."
            case .hostUnavailable(let provider):
                return "A host for \(provider.displayName) is unavailable. Reconnect the host before trying again."
            case .listNotLoaded: break
            case .available: preconditionFailure("An unavailable model lookup cannot contain an available model")
            }
        }
        return target.modelCatalog.newChatUnavailableReason(for: requestedNewChatProvider)
    }

    var serviceTierOverride: CodexAppServerV2.ServiceTierOverride? { pickerSelection.serviceTierOverride }

    @discardableResult
    func acceptThreadTierReadback(_ extra: CodexAppServerV2.ThreadExtra?, threadID: String,
                                  selectionRevision: UInt64) -> Bool {
        guard activeSessionID == threadID, pendingSettings[threadID] == nil else { return false }
        return pickerSelection.acceptTierReadback(extra, expectedRevision: selectionRevision)
    }

    func hasPendingSettings(threadID: String) -> Bool {
        pendingSettings[threadID] != nil
    }

    func selectionIsCurrent(revision: UInt64, threadID: String) -> Bool {
        settingsSelectionRevision == revision && pendingSettings[threadID] == nil
    }

    func rememberConversationSettings() {
        guard let threadID = activeSessionID, areConversationSettingsReady, let selectedModel else { return }
        target.recentConversations.record(.init(model: selectedModel, reasoning: reasoningSelection, fastModeState: fastModeState),
            threadID: threadID)
    }

    func showRecentSettings(threadID: String) {
        guard let settings = target.recentConversations.settings(threadID: threadID) else {
            pickerSelection.beginLoading()
            return
        }
        pickerSelection.showRecent(model: settings.model, reasoning: settings.reasoning, fastMode: settings.fastModeState)
        refreshReasoningVisibility()
    }

    func restoreConversationSettings(_ thread: ConversationHeader, loadID: UUID, revision: UInt64) async {
        let isCurrent = { self.isCurrentResumeLoad(loadID, threadID: thread.id) && self.settingsSelectionRevision == revision }
        guard isCurrent() else { return }
        if restorePendingConversationSettings(for: thread.id) { return }
        async let current = target.gatewayClient.readThread(threadID: thread.id, includeTurns: false)
        let saved = await target.metadataService.metadata(for: thread.id)
        guard isCurrent() else { return }
        var cachedThread = thread
        cachedThread.extra = nil
        restorePicker(from: cachedThread, saved: saved)
        do {
            let response = try await current
            let refreshed = await ConversationHeader.prepare(response.thread)
            guard isCurrent() else { return }
            restorePicker(from: refreshed, saved: saved)
        } catch {
            guard isCurrent() else { return }
            logger.notice("Could not refresh conversation settings thread=\(thread.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        if isCurrent() {
            pickerSelection.failIfLoading("Could not load this conversation’s model settings. Reopen the conversation to retry.")
        }
        if isCurrent() { refreshReasoningVisibility() }
    }

    @discardableResult
    func restorePendingConversationSettings(for threadID: String) -> Bool {
        guard activeSessionID == threadID, let pending = pendingSettings[threadID],
              let option = modelOption(id: pending.model, threadID: threadID, effort: pending.effort,
                                       fastMode: pending.fastMode == true) else { return false }
        pickerSelection.restore(model: option, reasoning: pending.reasoningSelection, fastMode: pending.fastModeState)
        refreshReasoningVisibility()
        return true
    }

    func restorePicker(from thread: ConversationHeader, saved: ConversationMetadata?) {
        adoptModelProvider(thread.modelProvider, threadID: thread.id)
        let source = pickerSelection.restore(from: thread, saved: saved) {
            modelOption(id: $0, threadID: thread.id, effort: $1, fastMode: $2)
        }
        guard let source, let model = selectedModel else { return }
        logger.notice("Restored conversation settings thread=\(thread.id, privacy: .public) model=\(model.id, privacy: .public) reasoning=\(self.reasoningSelection.id, privacy: .public) fast=\(self.fastModeSelection.map { String($0) } ?? "unknown", privacy: .public) source=\(source.rawValue, privacy: .public)")
    }

    func refreshNewChatDefaults(for provider: AgentProvider? = nil) {
        guard activeSessionID == nil else { return }
        let model = target.modelCatalog.newChatDefault(for: provider, health: target.providerHealth).model
        newChatModelSource = .resolvedDefault(provider)
        let reasoning = NewChatDefaults.reasoningSelection(defaults: target.chatDefaults)
        let fastMode = FastModeState.selection(NewChatDefaults.fastModeEnabled(defaults: target.chatDefaults))
        pickerSelection.choose(model: model, reasoning: model.map { visibleReasoning(reasoning, for: $0) } ?? reasoning,
                               fastMode: fastMode)
        recordBlankNewChatSetup()
    }

    func providerHealthChanged() {
        guard activeSessionID == nil, case .resolvedDefault(nil) = newChatModelSource,
              target.newChatDefaultModel().model?.id != selectedModel?.id else { return }
        refreshNewChatDefaults()
    }

    func pickerModelOptions(for selection: ModelOption) -> [ModelOption] {
        target.modelCatalog.pickerOptions(including: selection, threadModelProvider: activeModelProvider)
    }

    var providerNotice: String? {
        if activeSessionID != nil, let notice = activeModelProvider?.notice { return notice }
        guard let health = target.providerHealth, let model = selectedModel else { return nil }
        guard activeSessionID == nil else { return health.warning(for: model, isNewChat: false) }
        if case .resolvedDefault(nil) = newChatModelSource, let preferred = target.modelCatalog.preferredProvider,
           let notice = health.switchNotice(preferred: preferred, selected: model.provider) {
            return notice
        }
        return health.warning(for: model, isNewChat: true)
    }

    func applyModelCatalog(for provider: AgentProvider, visibilityBefore: ModelVisibility) {
        guard let current = selectedModel else {
            if case .unavailable(let modelID, _) = newChatModelSource {
                guard AgentProvider.provider(forModelID: modelID) == provider else { return }
                adoptSettings(modelID: modelID, reasoning: reasoningSelection, fastModeState: fastModeState, source: .draftSetup)
            } else {
                refreshNewChatDefaults(for: requestedNewChatProvider)
            }
            return
        }
        guard current.provider == provider else { return }
        let option: ModelOption?
        if let activeSessionID {
            option = modelOption(id: current.id, threadID: activeSessionID,
                effort: reasoningSelection.effort?.rawValue, fastMode: fastModeSelection == true)
        } else {
            option = target.configuredModel(id: current.id).model
        }
        if activeSessionID == nil, !keepsNewChatModel(option, visibilityBefore: visibilityBefore) {
            refreshNewChatDefaults(for: current.provider)
        } else if let option, option != current {
            pickerSelection.adoptModel(option)
            refreshReasoningVisibility()
        }
    }

    private func keepsNewChatModel(_ option: ModelOption?, visibilityBefore: ModelVisibility) -> Bool {
        guard let option else { return false }
        let visible = target.modelCatalog.isVisible(option, using: target.modelPickerPreferences.modelVisibility(for: option.provider))
        switch newChatModelSource {
        case .resolvedDefault: return visible
        case .chosen, .unavailable: return visible || !target.modelCatalog.isVisible(option, using: visibilityBefore)
        }
    }

    func selectDefaultModel(for provider: AgentProvider) {
        guard activeSessionID == nil else { return }
        if let option = target.modelCatalog.defaultModel(for: provider) {
            guard applyModel(option, for: nil, source: .providerDefault) else { return }
        } else {
            pickerSelection.clearModel()
        }
        newChatModelSource = .resolvedDefault(provider)
    }

    @discardableResult
    func adoptNewChatSettings(modelID: String, reasoning: ReasoningSelection,
                              fastModeState: FastModeState) -> Bool {
        adoptSettings(modelID: modelID, reasoning: reasoning, fastModeState: fastModeState, source: .movedDraft)
    }

    private func adoptSettings(modelID: String, reasoning: ReasoningSelection,
                               fastModeState: FastModeState, source: SettingsChangeSource) -> Bool {
        guard target.acceptsWork, activeSessionID == nil else { return false }
        let lookup = target.configuredModel(id: modelID)
        guard let option = lookup.model else {
            pickerSelection.choose(model: nil, reasoning: reasoning, fastMode: fastModeState)
            newChatModelSource = .unavailable(modelID: modelID, lookup: lookup)
            return false
        }
        applyPickerSettings(model: option, reasoning: visibleReasoning(reasoning, for: option), fastModeState: fastModeState,
                            threadID: nil, source: source)
        newChatModelSource = .chosen
        return true
    }

    func selectModel(_ option: ModelOption, for threadID: String?) {
        guard applyModel(option, for: threadID, source: .picker) else { return }
        if threadID == nil { newChatModelSource = .chosen }
        NewChatDefaults.recordModelSelection(option.id, defaults: target.chatDefaults)
    }

    private func applyModel(_ option: ModelOption, for threadID: String?, source: SettingsChangeSource) -> Bool {
        guard let current = pickerSettings(for: threadID),
              threadID.map({ AgentProvider.provider(forThreadID: $0) == option.provider }) ?? true else { return false }
        let reasoning = visibleReasoning(pickerSelection.rememberedReasoning(for: option) ?? current.reasoning, for: option)
        applyPickerSettings(model: option, reasoning: reasoning,
            fastModeState: current.fastModeState.changingModel(from: current.model, to: option),
            threadID: threadID, source: source)
        return true
    }

    func selectReasoning(_ selection: ReasoningSelection, for threadID: String?) {
        guard let current = pickerSettings(for: threadID), let model = current.model,
              visibleReasoning(selection, for: model) == selection else { return }
        pickerSelection.remember(selection, for: model)
        NewChatDefaults.recordReasoningSelection(selection, defaults: target.chatDefaults)
        applyPickerSettings(model: model, reasoning: selection,
            fastModeState: current.fastModeState, threadID: threadID, source: .picker)
    }

    func selectFastMode(_ enabled: Bool, for threadID: String?) {
        guard let current = pickerSettings(for: threadID), let model = current.model,
              !enabled || model.supportsFastMode else { return }
        NewChatDefaults.setFastModeEnabled(enabled, defaults: target.chatDefaults)
        applyPickerSettings(model: model, reasoning: current.reasoning,
            fastModeState: current.fastModeState.choosing(enabled), threadID: threadID, source: .picker)
    }

    private func visibleReasoning(_ selection: ReasoningSelection, for model: ModelOption) -> ReasoningSelection {
        target.modelPickerPreferences.clamped(selection, for: model)
    }

    func refreshReasoningVisibility() {
        guard target.acceptsWork else { return }
        if let selectedModel, activeSessionID == nil || areConversationSettingsReady {
            let selection = visibleReasoning(reasoningSelection, for: selectedModel)
            if selection != reasoningSelection {
                applyPickerSettings(model: selectedModel, reasoning: selection, fastModeState: fastModeState,
                                    threadID: activeSessionID, source: .reasoningVisibility)
            }
        }
        if let voice = voiceConversationSettings, voice.threadId != activeSessionID,
           let model = modelOption(id: voice.model, threadID: voice.threadId, effort: voice.effort, fastMode: voice.fastMode == true) {
            let selection = visibleReasoning(voice.reasoningSelection, for: model)
            if selection != voice.reasoningSelection {
                applyPickerSettings(model: model, reasoning: selection, fastModeState: voice.fastModeState,
                                    threadID: voice.threadId, source: .reasoningVisibility)
            }
        }
    }

    private func pickerSettings(for threadID: String?)
        -> (model: ModelOption?, reasoning: ReasoningSelection, fastModeState: FastModeState)? {
        guard target.acceptsWork else { return nil }
        if threadID == activeSessionID {
            return (selectedModel, reasoningSelection, fastModeState)
        }
        guard let settings = voiceConversationSettings, settings.threadId == threadID,
              let model = modelOption(id: settings.model, threadID: settings.threadId, effort: settings.effort,
                                      fastMode: settings.fastMode == true) else { return nil }
        return (model, settings.reasoningSelection, settings.fastModeState)
    }

    private enum SettingsChangeSource: String {
        case picker = "Manual picker selection"
        case providerDefault = "Provider default selection"
        case movedDraft = "Moved draft selection"
        case draftSetup = "Unsent draft setup"
        case reasoningVisibility = "Reasoning visibility clamp"
    }

    private func applyPickerSettings(model: ModelOption, reasoning: ReasoningSelection,
                                     fastModeState: FastModeState, threadID: String?,
                                     source: SettingsChangeSource) {
        logger.notice("\(source.rawValue, privacy: .public) thread=\(threadID ?? "new-chat", privacy: .public) model=\(model.id, privacy: .public) reasoning=\(reasoning.id, privacy: .public) fast=\(fastModeState.selection == true && model.supportsFastMode, privacy: .public)")
        if let threadID {
            applyConversationSettings(ConversationSettingsUpdate(threadID: threadID, model: model,
                reasoning: reasoning, fastModeState: fastModeState))
        } else {
            pickerSelection.choose(model: model, reasoning: reasoning, fastMode: fastModeState)
            switch source {
            case .picker, .providerDefault, .movedDraft: chooseNewChatSetup()
            case .draftSetup, .reasoningVisibility: break
            }
        }
    }

    func applySelectedConversationSettings() {
        guard target.acceptsWork, let threadID = activeSessionID,
              let settings = selectedConversationSettings(threadID: threadID) else { return }
        applyConversationSettings(settings)
    }

    private func selectedConversationSettings(threadID: String) -> ConversationSettingsUpdate? {
        guard let selectedModel else { return nil }
        return ConversationSettingsUpdate(threadID: threadID, model: selectedModel, reasoning: reasoningSelection,
                                          fastModeState: fastModeState)
    }

    func settingsNotice(for threadID: String?) -> String? {
        guard let threadID, let turnID = settingsDeferredUntilTurn[threadID],
              target.turns.turn(forThread: threadID)?.turnID == turnID else { return nil }
        return "New settings will be used after the current Claude turn finishes."
    }

    func settingsUpdateError(for threadID: String?) -> String? {
        if threadID == activeSessionID, let message = pickerSelection.unavailableMessage { return message }
        guard let threadID, case .failure(let message) = settingsFeedback[threadID] else { return nil }
        return message
    }

    func isUpdatingSettings(for threadID: String?) -> Bool {
        threadID.map { pendingSettings[$0] != nil } ?? false
    }

    func settingsUpdateWarning(for threadID: String?) -> String? {
        guard let threadID, case .deferred(let message) = settingsFeedback[threadID] else { return nil }
        return message
    }

    var voiceSelectedModel: ModelOption? {
        voiceConversationSettings.flatMap {
            modelOption(id: $0.model, threadID: $0.threadId, effort: $0.effort, fastMode: $0.fastMode == true)
        }
    }

    var voiceConversationSettings: ConversationSettingsUpdate? {
        guard target.realtimeVoice.callOwner == executionTarget,
              let context = target.realtimeVoice.conversationContext,
              let model = modelOption(id: context.model, threadID: context.threadID, effort: context.effort,
                                      fastMode: context.fastModeSelection == true) else { return nil }
        return pendingSettings[context.threadID] ?? ConversationSettingsUpdate(
            threadID: context.threadID, model: model,
            reasoning: context.effort.flatMap(ReasoningEffort.init(rawValue:)).map(ReasoningSelection.effort) ?? .automatic,
            fastModeState: context.fastModeState
        )
    }

    private func normalizedConversationSettings(
        _ settings: ConversationSettingsUpdate
    ) -> (settings: ConversationSettingsUpdate, model: ModelOption?) {
        guard let model = modelOption(id: settings.model, threadID: settings.threadId,
                                      effort: settings.effort, fastMode: settings.fastMode == true)
        else { return (settings, nil) }
        return (ConversationSettingsUpdate(threadID: settings.threadId, model: model,
                    reasoning: visibleReasoning(settings.reasoningSelection, for: model),
                    fastModeState: settings.fastModeState),
                model)
    }

    private func recordAppliedConversationSettings(_ settings: ConversationSettingsUpdate, currentTurnID: String?,
                                                   warning: String?) async {
        settingsDeferredUntilTurn[settings.threadId] = currentTurnID
        target.realtimeVoice.applyConversationSettings(settings, hostID: hostID)
        settingsFeedback[settings.threadId] = warning.map(SettingsFeedback.deferred)
        await target.metadataService.upsert(
            sessionID: settings.threadId, modelID: settings.model,
            reasoningSelectionID: settings.reasoningSelection.id,
            fastModeEnabled: settings.fastModeState.remembered,
            source: .selection
        )
    }

    func applyConversationSettings(_ requested: ConversationSettingsUpdate) {
        guard target.acceptsWork else { return }
        let (settings, model) = normalizedConversationSettings(requested)
        pendingSettings[settings.threadId] = settings
        if activeSessionID == settings.threadId, let option = model {
            let reasoning = settings.effort.flatMap(ReasoningEffort.init(rawValue:)).map(ReasoningSelection.effort) ?? .automatic
            pickerSelection.chooseForConversation(model: option, reasoning: reasoning, fastMode: settings.fastModeState)
        }
        settingsFeedback[settings.threadId] = nil
        guard !ownedTasks.isRunning(.settingsUpdate) else { return }
        ownedTasks.start(.settingsUpdate) { [weak self] in
            guard let self else { return }
            while let (threadID, settings) = pendingSettings.first {
                let feedback = target.feedbackForCurrentConversation()
                do {
                    try Task.checkCancellation()
                    guard target.acceptsWork else { return }
                    let response = try await target.gatewayClient.updateConversationSettings(settings)
                    guard target.acceptsWork else { return }
                    guard pendingSettings[threadID] == settings else { continue }
                    await recordAppliedConversationSettings(settings, currentTurnID: response.currentTurnId,
                                                            warning: response.warning)
                } catch is CancellationError {
                    return
                } catch {
                    guard target.acceptsWork else { return }
                    guard pendingSettings[threadID] == settings else { continue }
                    settingsFeedback[threadID] = .failure("Could not apply \(settings.model) settings: \(error.localizedDescription)")
                    if activeSessionID == threadID { feedback(.error) }
                }
                if pendingSettings[threadID] == settings { pendingSettings.removeValue(forKey: threadID) }
            }
        }
    }

    /// Entry points that promise a new conversation (the Voice Mode App Intent)
    /// pass `true`. The composer's voice
    /// button passes `false` and must keep the visible conversation.
    func prepareForVoiceModePresentation(
        startsFreshChat: Bool,
        configuration: RemoteCoderVoiceConfiguration? = nil
    ) throws {
        target.cancelConversationWarming()
        guard startsFreshChat else { return }
        let selection = try configuration?.validatedSelection(
            configuredModel: target.configuredModel(id:), defaultModel: target.newChatDefaultModel, preferences: target.modelPickerPreferences)
        startNewConversation()
        guard let selection else { return }
        pickerSelection.adopt(model: selection.model, reasoning: visibleReasoning(selection.reasoning, for: selection.model),
                              fastMode: .selection(selection.fastModeEnabled))
        newChatModelSource = .chosen
    }

    // MARK: - Realtime voice preparation

    func prepareRealtimeVoiceConversation() async throws -> RealtimeVoiceConversationContext {
        try await voicePreparation.prepare()
    }

    func beginVoicePreparation() throws -> RealtimeVoicePreparation.Target {
        guard areConversationSettingsReady else { throw RealtimeVoiceConversationContextError.settingsNotLoaded }
        refreshReasoningVisibility()
        let resumableThreadID = activeSessionID
        if resumableThreadID == nil && !messages.isEmpty { startNewConversation() }
        return .init(conversationID: currentConversationID, resumableThreadID: resumableThreadID, draft: currentDraft)
    }

    func captureVoiceStart(resumableThreadID: String?) throws -> RealtimeVoicePreparation.Start {
        guard let model = selectedModel else { throw ModelSelectionError.noModelForVoice }
        let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cwd.isEmpty else { throw AgentProviderError.workingDirectoryRequired(model.provider) }
        return .init(
            model: model, effort: reasoningSelection.effort?.rawValue, serviceTier: serviceTierOverride,
            fastMode: fastModeState, settingsRevision: settingsSelectionRevision,
            hadPendingSettings: resumableThreadID.flatMap { pendingSettings[$0] } != nil, cwd: cwd,
            history: messages.map {
                RealtimeVoiceHistoryMessage(role: $0.role == .user ? .user : .assistant, text: $0.text, date: $0.date)
            })
    }

    func adoptProvisionalVoiceThread(_ thread: CodexAppServerV2.Thread, conversationID: UUID,
                                     initialConfig: CodexAppServerV2.ThreadStartConfig?) async throws {
        setActiveSessionID(thread.id)
        await target.sessionIndex.record(sessionID: thread.id, conversationID: conversationID)
        await target.conversationList.record(ConversationHeader.prepare(thread))
        if let settings = settingsEstablished(byStarting: thread, with: initialConfig) {
            await recordAppliedConversationSettings(settings, currentTurnID: nil, warning: nil)
        } else {
            applySelectedConversationSettings()
        }
        await ownedTasks.value(.settingsUpdate)
        try Task.checkCancellation()
        if let settingsUpdateError = settingsUpdateError(for: thread.id) {
            throw RealtimeVoiceConversationContextError.settingsRejected(settingsUpdateError)
        }
    }

    private func settingsEstablished(byStarting thread: CodexAppServerV2.Thread,
                                     with initialConfig: CodexAppServerV2.ThreadStartConfig?) -> ConversationSettingsUpdate? {
        guard let initialConfig, target.acceptsWork, activeSessionID == thread.id, pendingSettings[thread.id] == nil,
              let selected = selectedConversationSettings(threadID: thread.id) else { return nil }
        let settings = normalizedConversationSettings(selected).settings
        guard settings.effort == initialConfig.modelReasoningEffort.rawValue,
              settings.matchesThreadSelection(thread) else { return nil }
        return settings
    }

    func present(_ session: ConversationSession) {
        observe(session)
    }

    func refreshRealtimeVoiceConversation(
        _ context: RealtimeVoiceConversationContext, using voiceGateway: GatewayClient
    ) async throws -> RealtimeVoiceConversationContext {
        let settingsRevision = settingsSelectionRevision
        let hadPendingSettings = pendingSettings[context.threadID] != nil
        let priorVoiceSettings = voiceConversationSettings
        let read = try await voicePreparation.refreshedContext(context, using: voiceGateway)
        var refreshed = read.context
        if target.acceptsWork, target.gatewayClient === voiceGateway, target.ownsActiveVoiceCall,
           target.realtimeVoice.conversationContext?.realtimeSessionID == context.realtimeSessionID,
           !hadPendingSettings, pendingSettings[context.threadID] == nil,
           settingsSelectionRevision == settingsRevision, voiceConversationSettings == priorVoiceSettings,
           let extra = read.thread.extra {
            refreshed.fastModeState = refreshed.fastModeState.reading(extra)
            acceptThreadTierReadback(extra, threadID: context.threadID, selectionRevision: settingsRevision)
            target.realtimeVoice.acceptConversationReadback(threadID: context.threadID,
                realtimeSessionID: context.realtimeSessionID, hostID: hostID)
        }
        return refreshed
    }

    func readIncomingVoiceSettings(_ context: RealtimeVoiceConversationContext,
                                   using voiceGateway: GatewayClient,
                                   ownsCall: @escaping @MainActor () -> Bool,
                                   readThread: @escaping @Sendable (String) async throws -> CodexAppServerV2.ThreadReadResponse)
        async -> VoiceIncomingSettingsRead {
        let settingsRevision = settingsSelectionRevision
        let visibleTargetAtStart = activeSessionID == context.threadID
        let incomingRevision = target.realtimeVoice.incomingSettingsRevision(
            for: context, hostID: hostID)
        let hadPendingSettings = pendingSettings[context.threadID] != nil
        let priorVoiceSettings = voiceConversationSettings
        let ownsRead = {
            !Task.isCancelled && !self.isRetired && self.target.gatewayClient === voiceGateway
                && ownsCall()
        }
        let isCurrent = {
            ownsRead() && !hadPendingSettings && self.pendingSettings[context.threadID] == nil
                && self.voiceConversationSettings == priorVoiceSettings
                && (!visibleTargetAtStart || self.settingsSelectionRevision == settingsRevision)
                && self.target.realtimeVoice.incomingSettingsRevision(
                    for: context, hostID: self.hostID) == incomingRevision
        }
        let rememberedState = await incomingVoiceFastModeState(for: context)
        var updated = context
        updated.fastModeState = rememberedState
        guard ownsRead() else { return .init(context: context, readModelAndEffort: false, readFastMode: false) }
        guard isCurrent() else { return .init(context: updated, readModelAndEffort: false, readFastMode: false) }
        do {
            let response = try await readThread(context.threadID)
            guard ownsRead() else { return .init(context: context, readModelAndEffort: false, readFastMode: false) }
            guard isCurrent(), response.thread.id == context.threadID else {
                return .init(context: updated, readModelAndEffort: false, readFastMode: false)
            }
            if let reportedModel = response.thread.model {
                updated.model = reportedModel
                updated.effort = response.thread.reasoningEffort?.rawValue
            }
            let reportsTier = response.thread.extra.map {
                $0.fastModeSelection != nil || $0.serviceTier != nil
            } ?? false
            if let extra = response.thread.extra, reportsTier {
                updated.fastModeState = updated.fastModeState.reading(extra)
                acceptThreadTierReadback(extra, threadID: context.threadID, selectionRevision: settingsRevision)
            }
            return .init(context: updated, readModelAndEffort: response.thread.model != nil,
                readFastMode: reportsTier)
        } catch {
            logger.notice("Could not read incoming voice tier thread=\(context.threadID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard ownsRead() else { return .init(context: context, readModelAndEffort: false, readFastMode: false) }
            return .init(context: updated, readModelAndEffort: false, readFastMode: false)
        }
    }

    func incomingVoiceFastModeState(for context: RealtimeVoiceConversationContext) async -> FastModeState {
        let saved = await target.metadataService.metadata(for: context.threadID)
        guard let saved,
              AgentProvider.provider(forModelID: saved.modelID) == AgentProvider.provider(forModelID: context.model) else {
            return context.fastModeState
        }
        return context.fastModeState.restoringPreference(saved.fastModeEnabled)
    }

    func discardProvisionalRealtimeVoiceConversation(threadID: String?) async {
        guard messages.isEmpty,
              let threadID,
              activeSessionID == threadID
        else { return }

        setActiveSessionID(nil)
        activeConversation = nil
        await target.sessionIndex.remove(sessionID: threadID)
        await target.conversationList.forget(threadID)
        logger.info("discarded failed provisional realtime voice thread")
    }

    // MARK: - Questions and focus

    /// Set by a question push tap; the screen reveals the card and clears it.
    private(set) var questionFocusRequest: QuestionFocusRequest?

    func requestQuestionFocus(itemID: String) {
        questionFocusRequest = QuestionFocusRequest(itemID: itemID, token: (questionFocusRequest?.token ?? 0) + 1)
    }

    func clearQuestionFocusRequest() {
        questionFocusRequest = nil
    }

    func questionAddress(itemID: String) -> QuestionAddress? {
        activeSessionID.map { QuestionAddress(conversation: .init(hostID: hostID, threadID: $0), itemID: itemID) }
    }

    func questionPrompt(for address: QuestionAddress) -> QuestionPrompt? {
        guard target.acceptsWork, address.conversation.target == executionTarget, address.conversation.threadID == activeSessionID else { return nil }
        return questionPrompts[address.itemID]
    }

    func questionEditor(for address: QuestionAddress, prompt: QuestionPrompt) -> QuestionEditor {
        target.questions.editor(for: address, prompt: prompt, activeThreadID: activeSessionID) { [weak self] address, entries, version in
            guard let self else { throw CancellationError() }
            return try await self.answerQuestion(address, entries: entries, version: version)
        }
    }

    func refreshQuestion(_ address: QuestionAddress) async {
        await target.questions.refresh(address)
    }

    /// Answers one model question card. The envelope is what the agent receives;
    /// the answers alone are what the transcript shows. It steers the running
    /// turn or starts a new one exactly like a typed message.
    func answerQuestion(_ address: QuestionAddress, entries: [QuestionReplyEnvelope.Entry], version: QuestionVersion) async throws -> UUID {
        let feedback = target.feedbackForCurrentConversation()
        do { return try await submitQuestion(address, entries: entries, version: version) }
        catch {
            if !(error is CancellationError) { feedback(.error) }
            throw error
        }
    }

    private func submitQuestion(_ address: QuestionAddress, entries: [QuestionReplyEnvelope.Entry], version: QuestionVersion) async throws -> UUID {
        guard address.conversation.hostID == hostID, address.conversation.threadID == activeSessionID,
              entries.allSatisfy({ $0.itemID == address.itemID }), !entries.isEmpty,
              questionPrompts[address.itemID]?.version == version
        else { throw ConversationState.QuestionSubmissionError.stale }
        if !canSteerCurrentConversation && !isCurrentConversationBusy,
           let message = idleQuestionSubmissionBlock?() {
            throw AccountServiceError.rejected(message)
        }
        guard target.acceptsWork, areConversationSettingsReady, let draft = currentDraft else { throw ConversationState.QuestionSubmissionError.notReady }
        if let block = currentConversationDispatchBlock { throw block }
        let replies = entries.map(\.reply)
        let resolved = ResolvedDispatchMessage(content: .question(text: QuestionReplyEnvelope.text(entries: entries),
            display: QuestionReply.displayText(replies)), fileAttachments: [])
        return try await dispatch(resolved, draft: draft, questionReplies: replies, interactionMode: .text,
                           expectedQuestionVersion: version)
    }
}

extension ChatScreenModel {
    var isRetired: Bool { target.isRetired }
    var hostID: UUID { target.hostID }
    var executionTarget: ExecutionTarget { target.target }
    var openThreadID: String? { activeSessionID ?? activeConversation?.id }

    var openAddress: ConversationAddress? {
        openThreadID.map { ConversationAddress(hostID: hostID, threadID: $0) }
    }
}

private struct SeenCompletion: Equatable {
    let threadID: String
    let completedAt: Int64
}
