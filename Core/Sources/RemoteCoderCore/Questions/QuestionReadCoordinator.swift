import Foundation

@MainActor
final class QuestionReadCoordinator {
    private let remote: any QuestionRemote
    private let sessions: ConversationSessions
    private let receive: @MainActor (String, [Int64]?) -> Void
    private var interests: [String: Set<String>] = [:]
    private struct Version { let epoch: String; let revision: UInt64 }
    private var known: [String: Version] = [:]
    private var invalidations: [String: Version] = [:]
    private var pending: Set<String> = []
    private var recency: [String] = []
    private var lifetime = UUID()
    private var task: Task<Void, Never>?
    private var stopped = false

    init(remote: any QuestionRemote, sessions: ConversationSessions,
         receive: @escaping @MainActor (String, [Int64]?) -> Void) {
        self.remote = remote
        self.sessions = sessions
        self.receive = receive
    }

    func request(threadID: String, itemIDs: [String] = []) {
        guard !stopped, !threadID.hasPrefix("claude_") else { return }
        recency.removeAll { $0 == threadID }
        recency.append(threadID)
        while recency.count > 32 {
            let retired = recency.removeFirst()
            interests.removeValue(forKey: retired)
            known.removeValue(forKey: retired)
            invalidations.removeValue(forKey: retired)
            pending.remove(retired)
        }
        let requested = Set(itemIDs.prefix(128))
        let retained = interests[threadID, default: []].subtracting(requested).sorted().prefix(max(0, 128 - requested.count))
        interests[threadID] = requested.union(retained)
        pending.insert(threadID)
        start()
    }

    func changed(threadID: String, epoch: String, revision: UInt64, itemIDs: [String]) {
        if let current = known[threadID], current.epoch == epoch, current.revision >= revision { return }
        invalidations[threadID] = Version(epoch: epoch, revision: revision)
        request(threadID: threadID, itemIDs: itemIDs)
    }

    func refresh(threadID: String, itemIDs: [String]) async {
        request(threadID: threadID, itemIDs: itemIDs)
        await task?.value
    }

    func invalidate() async {
        lifetime = UUID()
        let owner = lifetime
        task?.cancel()
        task = nil
        let threads = recency
        pending.removeAll()
        known.removeAll()
        invalidations.removeAll()
        for thread in threads {
            guard recency.contains(thread) else { continue }
            if let session = await sessions.existingSession(threadID: thread) {
                guard lifetime == owner, !stopped else { return }
                guard recency.contains(thread) else { continue }
                await session.invalidateQuestions("Question connection needs refreshing")
            }
            guard lifetime == owner, !stopped else { return }
            guard recency.contains(thread) else { continue }
            receive(thread, nil)
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        stopped = true
        lifetime = UUID()
        let owned = task
        owned?.cancel()
        task = nil
        pending.removeAll()
        return owned
    }

    func resume() { stopped = false }

    private func start() {
        guard task == nil, !pending.isEmpty else { return }
        let owner = lifetime
        task = Task { [weak self] in await self?.drain(owner: owner) }
    }

    private func drain(owner: UUID) async {
        defer { if lifetime == owner { task = nil; start() } }
        while !pending.isEmpty, lifetime == owner, !Task.isCancelled, !stopped {
            let threads = Array(recency.reversed().filter { pending.contains($0) }.prefix(16))
            pending.subtract(threads)
            let queries = threads.map { QuestionReadQuery(threadId: $0, itemIds: interests[$0, default: []].sorted()) }
            guard lifetime == owner, !Task.isCancelled else { return }
            do {
                let snapshots = try await remote.readQuestions(queries)
                for snapshot in snapshots {
                    guard lifetime == owner, !Task.isCancelled else { return }
                    guard recency.contains(snapshot.threadId) else { continue }
                    let ids = Set(snapshot.pendingItemIds ?? [])
                    interests[snapshot.threadId] = ids.union(interests[snapshot.threadId, default: []].subtracting(ids).sorted().prefix(max(0, 128 - ids.count)))
                    known[snapshot.threadId] = snapshot.coverage == .ready
                        ? Version(epoch: snapshot.epoch, revision: snapshot.revision) : nil
                    let served = Set(snapshot.records.map(\.itemId) + snapshot.missingItemIds)
                    let desired = invalidations[snapshot.threadId]
                    if desired == nil || desired?.epoch == snapshot.epoch && (desired?.revision ?? 0) <= snapshot.revision {
                        invalidations.removeValue(forKey: snapshot.threadId)
                        if interests[snapshot.threadId, default: []].isSubset(of: served) { pending.remove(snapshot.threadId) }
                    }
                    let askTimes: [Int64]?
                    if let session = await sessions.existingSession(threadID: snapshot.threadId) {
                        guard lifetime == owner, !Task.isCancelled else { return }
                        guard recency.contains(snapshot.threadId) else { continue }
                        let projected = try await session.mergeQuestions(snapshot)
                        askTimes = projected.questionCoverage == .ready
                            ? projected.questionPrompts.values.filter(\.isPending).compactMap(\.record?.askedAtMs).sorted()
                            : nil
                    } else {
                        askTimes = snapshot.coverage == .ready ? snapshot.pendingItemIds.map { pending in
                            let ids = Set(pending)
                            return snapshot.records.filter { ids.contains($0.itemId) }.compactMap(\.askedAtMs).sorted()
                        } : nil
                    }
                    guard lifetime == owner, !Task.isCancelled else { return }
                    guard recency.contains(snapshot.threadId) else { continue }
                    receive(snapshot.threadId, askTimes)
                }
            } catch {
                guard lifetime == owner, !Task.isCancelled else { return }
                for thread in threads {
                    guard recency.contains(thread) else { continue }
                    if let session = await sessions.existingSession(threadID: thread) {
                        guard lifetime == owner, !Task.isCancelled else { return }
                        guard recency.contains(thread) else { continue }
                        await session.invalidateQuestions(error.localizedDescription)
                    }
                    guard lifetime == owner, !Task.isCancelled else { return }
                    guard recency.contains(thread) else { continue }
                    receive(thread, nil)
                }
            }
        }
    }
}
