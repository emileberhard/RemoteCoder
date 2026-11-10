import OSLog
import SwiftUI

/// Streaming content is observed here, not by the screen's drawer, controls and sheets.
struct ConversationTranscriptView: View {
    #if os(macOS)
    @Environment(\.transcriptSurfaceRetention) private var retainedSurfaces
    #else
    private var retainedSurfaces: TranscriptSurfaceRetention? { nil }
    #endif
    let screen: ChatScreenModel
    let workspace: ChatWorkspaceModel
    let focus: ComposerFocus
    let onDismissComposerFocus: () -> Void
    @Binding var showsAgents: Bool
    let onOpenAgent: (ConversationAddress) -> Void
    let onReviewChanges: () -> Void
    let onEditAsFork: (ChatMessage) -> Void
    @State private var openURLAction: OpenURLAction
    @State private var agentOpener: AgentConversationOpener

    init(screen: ChatScreenModel, workspace: ChatWorkspaceModel, focus: ComposerFocus,
         onDismissComposerFocus: @escaping () -> Void,
         showsAgents: Binding<Bool>,
         onOpenAgent: @escaping (ConversationAddress) -> Void,
         onReviewChanges: @escaping () -> Void,
         onEditAsFork: @escaping (ChatMessage) -> Void) {
        self.screen = screen
        self.workspace = workspace
        self.focus = focus
        self.onDismissComposerFocus = onDismissComposerFocus
        _showsAgents = showsAgents
        self.onOpenAgent = onOpenAgent
        self.onReviewChanges = onReviewChanges
        self.onEditAsFork = onEditAsFork
        _openURLAction = State(initialValue: OpenURLAction { [weak screen] url in
            screen?.openFileURL(url, transition: nil, presentationScope: nil) ?? .discarded
        })
        _agentOpener = State(initialValue: AgentConversationOpener(hostID: screen.hostID, action: onOpenAgent))
    }
    private let logger = AppLogger(category: "ChatScreen")

    var body: some View {
        ZStack(alignment: .topLeading) {
            HTMLVisualPreparationHost()
            transcript
                .id(transcriptIdentity)
                #if os(macOS) && RC_PERF_HARNESS
                .environment(\.perfTranscriptAddress, screen.activeSessionID.map {
                    ConversationAddress(hostID: screen.hostID, threadID: $0)
                })
                #endif
        }
        .environment(\.openURL, openURLAction)
        .environment(\.agentConversationOpener, agentOpener)
        .htmlVisualEnvironment()
        .environment(\.htmlVisualCaptureAllowed, !screen.isCurrentConversationBusy)
        .environment(\.chatImageSource, ChatImageSource(screen: screen))
            .environment(\.htmlVisualSource, HTMLVisualSource(hostID: screen.hostID, documents: screen.htmlVisualDocuments,
                renderer: screen.htmlVisualRenderer, preparation: screen.htmlVisualPreparation))
            .environment(\.htmlVisualReplies, screen.htmlVisualReplies)
        .onChange(of: ObjectIdentifier(screen)) { [screen] _, _ in
            openURLAction = OpenURLAction { [weak screen] url in
                screen?.openFileURL(url, transition: nil, presentationScope: nil) ?? .discarded
            }
            agentOpener.hostID = screen.hostID
        }
        .onAppear {
            screen.markTranscriptFirstAppear()
        }
        .task(id: screen.changeSummary?.id) {
            screen.refreshChangeSummary()
        }
        #if os(iOS)
        .onChange(of: transcriptIdentity) { _, _ in
            focus.wrappedValue = false
        }
        #endif
        .onChange(of: transcriptIdentity, initial: true) { _, identity in
            logger.notice("transcript presents identity=\(identity)")
            showsAgents = false
        }
        .onChange(of: hasAgents) { _, hasAgents in
            if !hasAgents { showsAgents = false }
        }
    }

    private var deliveryActions: MessageDeliveryActions {
        var sendNow: ((ChatMessage) -> Void)?
        if !screen.canSteerCurrentConversation {
            sendNow = { [screen] message in screen.sendQueuedMessageNow(message) }
        }
        return MessageDeliveryActions(sendNow: sendNow, edit: { [screen] message in screen.editQueuedMessage(message) },
                                      remove: { [screen] message in screen.removeMessage(message) })
    }

    private var transcript: some View {
        ChatTranscriptView(
            items: screen.streamItems,
            readingPosition: screen.transcriptReadingPosition,
            rowPresentations: screen.transcriptRowPresentations,
            readingScope: screen.transcriptSurfaceID,
            retainedSurfaces: retainedSurfaces?.scope(owner: screen.transcriptSurfaceID),
            renderedMessages: screen.target.renderedMessages,
            forkableMessageIDs: screen.forkableMessageIDs,
            editBases: screen.editBases,
            scrollToRow: screen.pendingTranscriptRequest,
            onFork: { message in
                Task {
                    await screen.forkConversation(from: message)
                }
            },
            onEditAsFork: onEditAsFork,
            countChanges: screen.changeSummary.flatMap { summary in
                summary.offersViews ? ChangesStartAction(startTurnID: summary.startTurnID,
                                                         select: { [screen] in screen.countChanges(from: $0) }) : nil
            },
            deliveryActions: deliveryActions,
            onToggleTimeline: { jobID in
                #if os(iOS)
                onDismissComposerFocus()
                #endif
                screen.toggleTimeline(jobID: jobID)
            },
            questionCard: { ConversationQuestionView(screen: screen, prompt: $0) },
            onRefreshCompaction: screen.refreshCompactionStatus,
            onBackgroundTap: onDismissComposerFocus,
            historyEdgeStatus: screen.historyEdgeStatus,
            canPrefetchOlderHistory: screen.canPrefetchOlderHistory,
            canLoadHistory: screen.historyReadTarget != nil,
            onLoadHistory: screen.historyEdges.load,
            onShowLatest: screen.historyEdges.showLatest,
            onFirstContent: screen.markTranscriptFirstAppear,
            bottomBar: statusPills
        )
    }

    private var hasAgents: Bool { (screen.conversationAgents?.roster.count ?? 0) > 0 }

    private var statusPills: ConversationStatusPills? {
        let changes = screen.changeSummary.flatMap { $0.isVisible ? $0 : nil }
        let agents = hasAgents ? screen.conversationAgents : nil
        guard changes != nil || agents != nil else { return nil }
        return ConversationStatusPills(changes: changes, agents: agents, workspace: workspace, showsAgents: $showsAgents,
                                       onReviewChanges: onReviewChanges, onOpenAgent: onOpenAgent)
    }

    private var transcriptIdentity: String {
        "\(screen.hostID.uuidString)|\(screen.transcriptIdentity)"
    }
}
