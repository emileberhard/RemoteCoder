import Foundation
import OSLog

@MainActor
protocol ConversationWarmingHost: AnyObject {
    var mayWarm: Bool { get }
    var presentedConversationIDs: Set<UUID> { get }
    func refreshAgents(threadID: String) async
    func didWarm(_ snapshot: ConversationSnapshot, session: ConversationSession)
    var htmlVisualPreparationContext: HTMLVisualPreparationContext? { get }
    func prepareHTMLVisuals(_ references: [HTMLVisualReference]) async -> HTMLVisualPreparationOutcome
}

@MainActor
final class ConversationWarmer {
    private weak var host: (any ConversationWarmingHost)?
    private let conversations: ConversationSessions
    private let history: GatewayHistoryService
    private let logger = AppLogger(category: "ConversationWarmer")
    private var ledger = HistoryWarmLedger()

    init(host: any ConversationWarmingHost, conversations: ConversationSessions, history: GatewayHistoryService) {
        self.host = host
        self.conversations = conversations
        self.history = history
    }

    private var mayContinue: Bool { !Task.isCancelled && host?.mayWarm == true }

    func needsWarm(_ thread: ConversationHeader) -> Bool {
        ledger.needsWarm(threadID: thread.id, revision: thread.updatedAt, context: host?.htmlVisualPreparationContext)
    }

    func candidates(in ranked: [ConversationHeader]) -> [ConversationHeader] {
        ranked.prefix(5).filter(needsWarm)
    }

    func observation(threadID: String, revision: Int64) -> HistoryWarmLedger.Observation {
        ledger.observation(threadID: threadID, revision: revision)
    }

    func changed(_ threadID: String) { ledger.changed(threadID) }

    func prepareOpening(threadID: String) async -> ConversationSession? {
        let owner = await conversations.existingSession(threadID: threadID)
        if !Task.isCancelled, owner == nil { ledger.invalidate(threadID) }
        return owner
    }

    func needsRead(threadID: String, revision: Int64) -> Bool { ledger.readCovers(threadID: threadID, revision: revision) != true }

    func readSucceeded(threadID: String, observation: HistoryWarmLedger.Observation) {
        ledger.readSucceeded(threadID: threadID, observation: observation)
    }

    func invalidate(_ threadID: String) { ledger.invalidate(threadID) }

    func clear() { ledger.clear() }

    func warm(_ threads: [ConversationHeader], hot: Set<String>, agentThreadIDs: [String]) async {
        logger.notice("warm pass threads=\(threads.count) hot=\(hot.count) agents=\(agentThreadIDs.count)")
        for threadID in agentThreadIDs {
            guard mayContinue else { return }
            await host?.refreshAgents(threadID: threadID)
        }
        for thread in threads {
            guard mayContinue else { return }
            let observation = ledger.observation(threadID: thread.id, revision: thread.updatedAt)
            let covered = ledger.readCovers(threadID: thread.id, revision: thread.updatedAt)
            do {
                let tail: HistoryWindow
                let source: String
                if hot.contains(thread.id) {
                    let session = await conversations.session(threadID: thread.id)
                    guard mayContinue else { return }
                    try await session.restore()
                    guard mayContinue else { return }
                    let read = await session.beginHistoryRead()
                    let page = try await history.openTail(header: thread, base: read.base, priority: .prefetch,
                        bypassCache: covered != true)
                    guard mayContinue else { return }
                    let snapshot = await session.merge(page, read: read)
                    guard mayContinue else { return }
                    host?.didWarm(snapshot, session: session)
                    ledger.readSucceeded(threadID: thread.id, observation: observation)
                    tail = page.window
                    source = "hot"
                } else if let stored = await history.cachedConversation(header: thread),
                          covered ?? (stored.fetchedAt.timeIntervalSince1970 > Double(thread.updatedAt + 1)) {
                    tail = stored.window
                    source = "stored"
                } else {
                    tail = try await history.openTail(header: thread, base: nil, priority: .prefetch, bypassCache: true).window
                    guard mayContinue else { return }
                    ledger.readSucceeded(threadID: thread.id, observation: observation)
                    source = "read"
                }
                guard mayContinue, let host else { return }
                guard let context = host.htmlVisualPreparationContext else {
                    ledger.succeeded(threadID: thread.id, observation: observation, context: nil)
                    logger.notice("warmed thread=\(thread.id) revision=\(thread.updatedAt) source=\(source) outcome=historyOnly")
                    continue
                }
                let references = await Self.visualReferences(in: tail)
                guard mayContinue else { return }
                let outcome = await host.prepareHTMLVisuals(references)
                logger.notice("warmed thread=\(thread.id) revision=\(thread.updatedAt) source=\(source) visuals=\(references.count) outcome=\(String(describing: outcome))")
                switch outcome {
                case .settled, .unsupported:
                    guard mayContinue, host.htmlVisualPreparationContext == context else { return }
                    ledger.succeeded(threadID: thread.id, observation: observation, context: context)
                case .incomplete: continue
                case .interrupted: return
                }
            } catch is CancellationError {
                return
            } catch {
                logger.notice("History prefetch failed: \(error.localizedDescription)")
            }
        }
        guard let host else { return }
        await conversations.evictIdle(keeping: host.presentedConversationIDs)
    }

    @concurrent private static func visualReferences(in window: HistoryWindow) async -> [HTMLVisualReference] {
        var seen = Set<String>()
        return window.turns.reversed().flatMap { $0.entries.reversed() }.flatMap { entry -> [HTMLVisualReference] in
            if let visual = entry.item.publishedVisual { return [visual.reference] }
            guard case .agentMessage(_, let text, _, _, _) = entry.item else { return [] }
            return HTMLVisualReference.references(inMarkdown: text)
        }.filter { seen.insert($0.digest).inserted }
    }
}
