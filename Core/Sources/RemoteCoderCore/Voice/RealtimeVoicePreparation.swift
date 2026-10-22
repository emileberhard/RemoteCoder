import Foundation

@MainActor
protocol RealtimeVoicePreparationHost: AnyObject {
    var isRetired: Bool { get }
    var currentConversationID: UUID { get }
    var activeSessionID: String? { get }
    var pickerSelection: ConversationSettingsSelection { get }

    func beginVoicePreparation() throws -> RealtimeVoicePreparation.Target
    func captureVoiceStart(resumableThreadID: String?) throws -> RealtimeVoicePreparation.Start
    func hasPendingSettings(threadID: String) -> Bool
    func adoptProvisionalVoiceThread(_ thread: CodexAppServerV2.Thread, conversationID: UUID,
                                     initialConfig: CodexAppServerV2.ThreadStartConfig?) async throws
    func present(_ session: ConversationSession)
    @discardableResult func acceptThreadTierReadback(_ extra: CodexAppServerV2.ThreadExtra?, threadID: String, selectionRevision: UInt64) -> Bool
    func discardProvisionalRealtimeVoiceConversation(threadID: String?) async
}

@MainActor
final class RealtimeVoicePreparation {
    struct Target {
        let conversationID: UUID
        let resumableThreadID: String?
        let draft: ComposerDraft?
    }

    struct Start {
        let model: ModelOption
        let effort: String?
        let serviceTier: CodexAppServerV2.ServiceTierOverride?
        let fastMode: FastModeState
        let settingsRevision: UInt64
        let hadPendingSettings: Bool
        let cwd: String
        let history: [RealtimeVoiceHistoryMessage]

        var initialThreadConfig: CodexAppServerV2.ThreadStartConfig? {
            guard model.provider == .codex,
                  let effort = effort.flatMap(CodexAppServerV2.ReasoningEffort.init(rawValue:)) else { return nil }
            return .init(modelReasoningEffort: effort)
        }
    }

    private weak var host: (any RealtimeVoicePreparationHost)?
    private let gateway: GatewayClient
    private let conversations: ConversationSessions
    private let history: GatewayHistoryService
    private let voiceHistory: RealtimeVoiceHistoryStore
    private let drafts: ComposerDraftStore

    init(host: any RealtimeVoicePreparationHost, gateway: GatewayClient, conversations: ConversationSessions,
         history: GatewayHistoryService, voiceHistory: RealtimeVoiceHistoryStore, drafts: ComposerDraftStore) {
        self.host = host
        self.gateway = gateway
        self.conversations = conversations
        self.history = history
        self.voiceHistory = voiceHistory
        self.drafts = drafts
    }

    func prepare() async throws -> RealtimeVoiceConversationContext {
        guard let host else { throw CancellationError() }
        let target = try host.beginVoicePreparation()
        let conversationID = target.conversationID
        try await gateway.verifyDispatchAllowed(to: target.resumableThreadID)
        guard host.currentConversationID == conversationID else {
            throw RealtimeVoiceConversationContextError.conversationChanged
        }
        let start = try host.captureVoiceStart(resumableThreadID: target.resumableThreadID)
        let initialConfig = target.resumableThreadID == nil ? start.initialThreadConfig : nil
        let thread: CodexAppServerV2.Thread
        if let resumableThreadID = target.resumableThreadID {
            thread = try await gateway.resumeThreadPreservingSettings(threadID: resumableThreadID)
        } else {
            thread = try await gateway.startThread(
                model: start.model.id,
                cwd: start.cwd,
                serviceTier: start.serviceTier,
                provider: start.model.provider,
                serviceName: "RemoteCoder Voice",
                config: initialConfig
            )
        }
        do {
            try Task.checkCancellation()
            guard host.currentConversationID == conversationID else {
                throw RealtimeVoiceConversationContextError.conversationChanged
            }
            if target.resumableThreadID == nil {
                try await host.adoptProvisionalVoiceThread(thread, conversationID: conversationID,
                                                           initialConfig: initialConfig)
            }
            let conversation = await conversations.session(conversationID: conversationID, threadID: thread.id)
            if host.currentConversationID == conversationID { host.present(conversation) }
            let storedVoiceMessages = await voiceHistory.entries(for: thread.id).map {
                RealtimeVoiceHistoryMessage(role: $0.role, text: $0.text, date: $0.date)
            }
            let chatMessages = target.resumableThreadID != nil && start.history.isEmpty
                ? try await canonicalHistory(of: thread, in: conversation)
                : start.history
            try Task.checkCancellation()
            let selection = host.pickerSelection
            guard !host.isRetired, host.currentConversationID == conversationID,
                  host.activeSessionID == thread.id, selection.isReady else {
                throw RealtimeVoiceConversationContextError.conversationChanged
            }
            let useVoiceReadback = !start.hadPendingSettings && selection.revision == start.settingsRevision
                && !host.hasPendingSettings(threadID: thread.id)
            let contextModel = useVoiceReadback ? start.model : selection.model ?? start.model
            let contextEffort = useVoiceReadback ? start.effort : selection.reasoning.effort?.rawValue
            if useVoiceReadback {
                host.acceptThreadTierReadback(thread.extra, threadID: thread.id, selectionRevision: start.settingsRevision)
            }
            let contextFastMode = useVoiceReadback ? start.fastMode.reading(thread.extra) : selection.fastMode
            let context = RealtimeVoiceConversationContext(
                threadID: thread.id,
                realtimeSessionID: conversationID.uuidString.lowercased(),
                isProvisionalThread: target.resumableThreadID == nil,
                model: contextModel.id,
                effort: contextEffort,
                cwd: start.cwd,
                fastModeState: contextFastMode,
                history: RealtimeVoiceConversationHistory.merged(
                    chatMessages: chatMessages, voiceMessages: storedVoiceMessages
                )
            )
            try Task.checkCancellation()
            if !host.isRetired, let draft = target.draft { await drafts.bind(draft, to: thread.id) }
            try Task.checkCancellation()
            guard !host.isRetired else { throw CancellationError() }
            return context
        } catch {
            if target.resumableThreadID == nil {
                await host.discardProvisionalRealtimeVoiceConversation(threadID: thread.id)
            }
            throw error
        }
    }

    func refreshedContext(_ context: RealtimeVoiceConversationContext, using voiceGateway: GatewayClient)
        async throws -> (thread: CodexAppServerV2.Thread, context: RealtimeVoiceConversationContext) {
        try await voiceGateway.verifyDispatchAllowed(to: context.threadID)
        let thread = try await voiceGateway.resumeThreadPreservingSettings(threadID: context.threadID)
        try Task.checkCancellation()
        guard thread.id == context.threadID else { throw RealtimeVoiceConversationContextError.conversationChanged }
        let session = await conversations.session(threadID: context.threadID)
        let canonical = try await canonicalHistory(of: thread, in: session)
        let voiceMessages = await voiceHistory.entries(for: context.threadID).map {
            RealtimeVoiceHistoryMessage(role: $0.role, text: $0.text, date: $0.date)
        }
        try Task.checkCancellation()
        return (thread, context.refreshingHistory(chatMessages: canonical, voiceMessages: voiceMessages))
    }

    private func canonicalHistory(of thread: CodexAppServerV2.Thread, in session: ConversationSession)
        async throws -> [RealtimeVoiceHistoryMessage] {
        let read = await session.beginHistoryRead()
        let snapshot = try await history.openTail(header: ConversationHeader.prepare(thread), base: read.base)
        return await session.merge(snapshot, read: read).messages.map {
            RealtimeVoiceHistoryMessage(role: $0.role == .user ? .user : .assistant, text: $0.text, date: $0.date)
        }
    }
}
