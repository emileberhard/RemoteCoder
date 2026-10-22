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
    let focus: ComposerFocus
    let onDismissComposerFocus: () -> Void
    let onShowAgents: (ConversationAgentsModel) -> Void
    @State private var openURLAction: OpenURLAction

    init(screen: ChatScreenModel, focus: ComposerFocus,
         onDismissComposerFocus: @escaping () -> Void,
         onShowAgents: @escaping (ConversationAgentsModel) -> Void) {
        self.screen = screen
        self.focus = focus
        self.onDismissComposerFocus = onDismissComposerFocus
        self.onShowAgents = onShowAgents
        _openURLAction = State(initialValue: OpenURLAction { [weak screen] url in
            screen?.openFileURL(url, transition: nil, presentationScope: nil) ?? .discarded
        })
    }
    private let logger = Logger(subsystem: "RemoteCoder", category: "ChatScreen")

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
                .transcriptConversationTransition()
        }
        .environment(\.openURL, openURLAction)
        .htmlVisualEnvironment()
        .environment(\.htmlVisualCaptureAllowed, !screen.isCurrentConversationBusy)
        .environment(\.chatImageSource, ChatImageSource(screen: screen))
            .environment(\.htmlVisualSource, HTMLVisualSource(hostID: screen.hostID, documents: screen.htmlVisualDocuments,
                renderer: screen.htmlVisualRenderer, preparation: screen.htmlVisualPreparation))
        .onChange(of: ObjectIdentifier(screen)) { [screen] _, _ in
            openURLAction = OpenURLAction { [weak screen] url in
                screen?.openFileURL(url, transition: nil, presentationScope: nil) ?? .discarded
            }
        }
        .transcriptConversationAnimation(identity: transcriptIdentity)
        .onAppear {
            screen.markTranscriptFirstAppear()
        }
        #if os(iOS)
        .onChange(of: transcriptIdentity) { _, _ in
            focus.wrappedValue = false
        }
        #endif
        .onChange(of: transcriptIdentity, initial: true) { _, identity in
            logger.notice("transcript presents identity=\(identity, privacy: .public)")
        }
    }

    private var queuedActions: QueuedMessageActions {
        var sendNow: ((ChatMessage) -> Void)?
        if !screen.canSteerCurrentConversation {
            sendNow = { [screen] message in screen.sendQueuedMessageNow(message) }
        }
        return QueuedMessageActions(sendNow: sendNow, remove: { [screen] message in screen.removeQueuedMessage(message) })
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
            scrollToRow: screen.pendingTranscriptRequest,
            onFork: { message in
                Task {
                    await screen.forkConversation(from: message)
                }
            },
            queuedActions: queuedActions,
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
            bottomBar: screen.conversationAgents.flatMap { agents in
                agents.summary.flatMap { summary in
                    summary.total == 0 ? nil : SubagentsPill(agents: agents, recent: summary.recent) {
                        onShowAgents(agents)
                    }
                }
            }
        )
    }

    private var transcriptIdentity: String {
        "\(screen.hostID.uuidString)|\(screen.transcriptIdentity)"
    }
}
