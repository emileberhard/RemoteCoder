import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationSessionTests: ConversationHistoryFixtures {
    @Test func invalidatedSessionEpochsAreReleasedAfterCreationAndRetirementFinish() async {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let sessions = ConversationSessions(hostID: host, sessionIndex: ConversationIndex(hostID: host, storage: temporary.storage), contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        for index in 0..<128 {
            let thread = "invalidated-session-\(index)"
            _ = await sessions.session(conversationID: ChatMessage.deterministicID(for: thread), threadID: thread)
            await sessions.invalidate(threadID: thread)
            #expect(await sessions.retainedEpochCount == 0)
            #expect(await sessions.retainedCheckpointFenceCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func completingBusySessionsEvictsTheOverCapacityCacheWithoutANewAdmission() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID, sessionIndex: ConversationIndex(hostID: hostID,
            storage: temporary.storage), contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        var owners: [ConversationSession] = []
        var observers: [Task<Void, Never>] = []
        for index in 0..<40 {
            let threadID = "thread-\(index)"
            let owner = await registry.session(threadID: threadID)
            owners.append(owner)
            let stream = await owner.snapshots()
            observers.append(Task { for await _ in stream {} })
            await registry.ingest(try GatewayEventFixture.turn("turn/started", params: [
                "threadId": .string(threadID), "turn": .object(["id": .string("turn"), "status": .string("inProgress")])
            ]), replay: false)
        }
        #expect(await registry.openThreadIDs().count == 40)
        for observer in observers { observer.cancel() }
        for observer in observers { await observer.value }
        let retained = owners
        try await eventually {
            for owner in retained where await !owner.canEvict { return false }
            return true
        }
        #expect(await registry.openThreadIDs().count == 40)
        for index in 0..<40 {
            await registry.ingest(try GatewayEventFixture.turn("turn/completed", params: [
                "threadId": .string("thread-\(index)"), "turn": .object(["id": .string("turn"), "status": .string("completed")])
            ]), replay: false)
        }
        let retainedAfterCompletion = await registry.openThreadIDs().count
        #expect(retainedAfterCompletion == 16)
    }

    @Test func contentSubscriptionsFollowRetainedBindingsAndKeepExternallyHeldOwners() async {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let subscriptions = RecordingContentSubscriptions()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: subscriptions, storage: temporary.storage)
        let draft = await sessions.session(conversationID: UUID())
        #expect(await subscriptions.threadIDs.isEmpty)
        let bound = await sessions.session(conversationID: draft.conversationID, threadID: "claude_bound")
        #expect(bound === draft)
        #expect(await subscriptions.threadIDs == ["claude_bound"])
        let boundRevision = await subscriptions.revision
        for _ in 0..<8 {
            #expect(await sessions.session(conversationID: draft.conversationID, threadID: "claude_bound") === draft)
            #expect(await sessions.session(threadID: "claude_bound") === draft)
            await sessions.evictIdle(keeping: [])
        }
        #expect(await subscriptions.revision == boundRevision)
        var retained: ConversationSession? = await sessions.session(threadID: "claude_retained")
        weak let weakOwner = retained
        for index in 0..<20 { _ = await sessions.session(threadID: "claude_other-\(index)") }
        #expect(await !sessions.openThreadIDs().contains("claude_retained"))
        #expect(await subscriptions.threadIDs.contains("claude_retained"))
        #expect(await subscriptions.threadIDs.contains("claude_bound"))
        #expect(weakOwner === retained)
        retained = nil
        for index in 20..<40 { _ = await sessions.session(threadID: "claude_other-\(index)") }
        #expect(weakOwner == nil)
        #expect(await !subscriptions.threadIDs.contains("claude_retained"))
        #expect(await subscriptions.threadIDs.count <= 17)
        _ = await sessions.session(threadID: "native")
        #expect(await !subscriptions.threadIDs.contains("native"))
        let retiring = await subscriptions.threadIDs
        for thread in retiring { await sessions.invalidate(threadID: thread) }
        #expect(await subscriptions.threadIDs.isEmpty)
        await sessions.invalidate(threadID: "native")
        withExtendedLifetime((draft, bound)) {}
    }

    @Test @MainActor func globalActivityDoesNotCreateTranscriptsAndRetainedOwnersStillReceiveEvents() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let selected = await sessions.session(threadID: "selected")
        let retained = await sessions.session(threadID: "retained")
        let threads = ["selected", "retained"] + (0..<96).map { "foreign-\($0)" }
        let turns = TurnRegistry()
        let snapshot = ActiveTurnsFixture.snapshot(active: threads.map { ActiveTurnsFixture.turn(thread: $0, id: "turn") })
        _ = turns.apply(snapshot, observedAt: ActiveTurnsFixture.observed)
        let activity = ConversationActivity(snapshot: snapshot)
        for thread in threads {
            let started = try GatewayEventFixture.turn("turn/started", params: [
                "threadId": .string(thread), "turn": .object(["id": .string("turn"), "status": .string("inProgress")])
            ])
            await sessions.ingest(started, replay: false)
            await sessions.ingest(try event("item/completed", item: .agentMessage(id: "reply", text: thread), ordinal: 1,
                threadID: thread), replay: true)
        }
        await sessions.synchronizeActivity(turns.runningTurns)
        #expect(await sessions.openThreadIDs().count == 2)
        #expect(turns.liveActivityTaskCount == threads.count)
        #expect(turns.busyThreadIDs == Set(threads))
        #expect(threads.allSatisfy { activity.state(for: $0) == .working })
        let attention = AttentionSummary(hosts: [.init(hostID: hostID, hostName: "Host",
            threads: threads.map { .historyFixture(id: $0) }, marks: ConversationMarksReplica().effective,
            remoteHomePath: nil, activityByThreadID: Dictionary(uniqueKeysWithValues: threads.map { ($0, activity.state(for: $0)) }),
            activeThreadID: "selected", loadingThreadID: nil, isLoading: false, errorMessage: nil,
            questionAskTimesByThreadID: [:])], limit: 8, at: .now)
        #expect(attention.runningCount == threads.count)
        #expect(attention.entries.count == 8)
        #expect(await selected.snapshot().messages.map(\.text) == ["selected"])
        #expect(await retained.snapshot().messages.map(\.text) == ["retained"])
        for thread in threads {
            await sessions.ingest(try GatewayEventFixture.turn("turn/completed", params: [
                "threadId": .string(thread), "turn": .object(["id": .string("turn"), "status": .string("completed")])
            ]), replay: true)
            #expect(turns.complete(threadID: thread, turnID: "turn") != nil)
        }
        await sessions.synchronizeActivity(turns.runningTurns)
        #expect(turns.liveActivityTaskCount == 0)
        #expect(turns.busyThreadIDs.isEmpty)
        #expect(await sessions.openThreadIDs().count == 2)
        for thread in threads { await sessions.invalidate(threadID: thread) }
    }

    @Test func unobservedActiveSessionsUseTheRetentionLimitWhileObserversAndSubmissionsRemainOwned() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let observed = await sessions.session(threadID: "observed")
        let stream = await observed.snapshots()
        let submitting = await sessions.session(threadID: "submitting")
        _ = try await submitting.submitDurably(ChatMessage(role: .user, text: "Pending"))
        for index in 0..<32 {
            let session = await sessions.session(threadID: "active-\(index)")
            await session.activity(turnID: "turn", active: true)
        }
        let retained = Set(await sessions.openThreadIDs())
        #expect(retained.count == 16)
        #expect(retained.contains("observed"))
        #expect(retained.contains("submitting"))
        #expect(!retained.contains("active-0"))
        #expect(retained.contains("active-31"))
        withExtendedLifetime(stream) {}
        for thread in retained { await sessions.invalidate(threadID: thread) }
    }

    @Test func backgroundLookupsDoNotDisplaceTheLeastRecentlyPresentedOwner() async {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let ids = (0..<17).map { ChatMessage.deterministicID(for: "thread-\($0)") }
        for index in 0..<16 {
            _ = await sessions.session(conversationID: ids[index], threadID: "thread-\(index)")
        }
        _ = await sessions.session(conversationID: ids[0], threadID: "thread-0")
        _ = await sessions.session(threadID: "thread-1")
        _ = await sessions.session(conversationID: ids[16], threadID: "thread-16")
        let retained = Set(await sessions.openThreadIDs())
        #expect(retained.count == 16)
        #expect(retained.contains("thread-0"))
        #expect(!retained.contains("thread-1"))
        #expect(retained.contains("thread-2"))
        for thread in retained { await sessions.invalidate(threadID: thread) }
    }

    @Test func finalFlushIncludesRetainedEvictedSessionsAndReportsRetryableFailure() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let registry = ConversationSessions(hostID: host, sessionIndex: ConversationIndex(hostID: host, storage: temporary.storage), contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let original = await registry.session(threadID: "original")
        for index in 0..<24 { _ = await registry.session(threadID: "other-\(index)") }
        await original.ingest(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1,
            threadID: "original"), replay: false)
        await original.ingest(try GatewayEventFixture.delta("Admitted late text", threadID: "original", turnID: "turn", itemID: "answer"), replay: false)
        let directory = temporary.storage.directory(for: .device).appending(path: "conversations-v1/\(host)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let failed = await registry.flush()
        #expect(failed.contains { $0.conversationID == original.conversationID })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(await registry.flush().isEmpty)
        let checkpoint = try #require(try await ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(original.conversationID))
        var state = ConversationState(conversationID: original.conversationID, threadID: "original")
        state.restore(checkpoint)
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["Admitted late text"])
    }

    @Test func aPageReadAgainstAReplacedWindowIsRejected() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread", checkpoints: ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
        _ = await session.merge(.fixture(wire: entries([.agentMessage(id: "old", text: "Old")], turnID: "old"), older: "before-old"))
        let base = try #require(await session.beginHistoryRead().base)
        _ = await session.merge(.fixture(wire: entries([.agentMessage(id: "new", text: "Current")], turnID: "new"), older: "before-new",
            base: await session.beginHistoryRead().base))
        let final = await session.merge(.fixture(wire: entries([.agentMessage(id: "older", text: "Older")], turnID: "older"),
            placement: .older("before-old"), base: base))
        #expect(await session.beginHistoryRead().base?.turns.map(\.id) == ["new"])
        #expect(final.messages.map(\.text) == ["Current"])
    }

    @Test func draftBindingAdoptsEarlyEventsAndRedirectsAlreadyQueuedDeliveries() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID, sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let draft = await registry.session(conversationID: UUID())
        let message = ChatMessage(role: .user, text: "Draft")
        _ = try await draft.submitDurably(message)
        let early = await registry.session(threadID: "thread")
        await early.ingest(try event("item/completed", item: .agentMessage(id: "first", text: "Early"), ordinal: 1), replay: false)
        let bound = await registry.session(conversationID: draft.conversationID, threadID: "thread")
        #expect(bound === draft)
        #expect(await registry.session(threadID: "thread") === draft)
        await early.ingest(try event("item/completed", item: .agentMessage(id: "later", text: "Queued"), ordinal: 2), replay: false)
        #expect(Set(await bound.snapshot().messages.map(\.text)) == ["Draft", "Early", "Queued"])
        await registry.invalidate(threadID: "thread")
    }

    @Test func aTailReadThatStartedEarlierCannotReplaceTheCoverageOfALaterOne() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread", checkpoints: ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
        let items = (1...55).map { CodexAppServerV2.ThreadItem.agentMessage(id: "e\($0)", text: "Entry \($0)") }
        let earlier = await session.beginHistoryRead()
        let later = await session.beginHistoryRead()
        _ = await session.merge(.fixture(wire: entries(Array(items[5...]), turnID: "turn"), older: "before-e6"), read: later)
        _ = await session.merge(.fixture(wire: entries(Array(items[..<50]), turnID: "turn"), older: nil), read: earlier)
        let covered = await session.beginHistoryRead().base?.turn("turn")?.entries.map(\.item.id)
        #expect(covered?.first == "e6")
        #expect(covered?.last == "e55")
    }

    @Test func externallyRetainedSessionKeepsIdentityAcrossCacheEvictionThenReleases() async {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID, sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        var original: ConversationSession? = await registry.session(threadID: "original")
        weak var released = original
        for index in 0..<20 { _ = await registry.session(threadID: "other-\(index)") }
        await registry.evictIdle(keeping: [])
        #expect(await registry.retainedEpochCount <= 17)
        #expect(await registry.retainedCheckpointFenceCount <= 17)
        #expect(await registry.session(threadID: "original") === original)
        original = nil
        for index in 20..<40 { _ = await registry.session(threadID: "other-\(index)") }
        #expect(released == nil)
        await registry.evictIdle(keeping: [])
        #expect(await registry.retainedEpochCount <= 16)
        #expect(await registry.retainedCheckpointFenceCount <= 16)
        await registry.invalidate(threadID: "original")
        for index in 0..<40 { await registry.invalidate(threadID: "other-\(index)") }
    }

    @Test func prunedThreadBindingResolvesToItsIndexedLocalConversation() async {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let index = ConversationIndex(hostID: hostID, storage: temporary.storage)
        let registry = ConversationSessions(hostID: hostID, sessionIndex: index,
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let local = UUID()
        await index.record(sessionID: "bound", conversationID: local)
        _ = await registry.session(conversationID: local, threadID: "bound")
        for index in 0..<40 { _ = await registry.session(threadID: "filler-\(index)") }
        #expect(await registry.session(threadID: "bound").conversationID == local)
        await index.remove(sessionID: "bound")
        await registry.invalidate(threadID: "bound")
        for index in 0..<40 { await registry.invalidate(threadID: "filler-\(index)") }
    }

    @Test func newNotificationEpochAcceptsReusedSequences() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID, sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let session = await registry.session(threadID: "thread")
        await session.ingest(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1), replay: false)
        await registry.adoptNotificationEpoch("before-restart")
        for (epoch, text) in [("before-restart", "one "), ("before-restart", "duplicate "), ("after-restart", "two")] {
            await registry.adoptNotificationEpoch(epoch)
            let note = GatewayEventFixture.notification(method: "item/agentMessage/delta", params: .object([
                "threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("answer"), "delta": .string(text)
            ]), sequence: 7)
            guard case .turnEvent(let event) = try #require(GatewayNotificationRouting.route(note)) else { throw GatewayEventFixture.Failure.invalidEvent }
            await session.ingest(event, replay: false)
        }
        #expect(await session.snapshot().messages.map(\.text) == ["one two"])
        await registry.invalidate(threadID: "thread")
    }

    @Test func invalidationRejectsTheOldOwnersWriteButAllowsTheReplacement() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let registry = ConversationSessions(hostID: hostID, sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let original = await registry.session(threadID: "thread")
        await registry.invalidate(threadID: "thread")
        let replacement = await registry.session(threadID: "thread")
        #expect(replacement !== original)
        #expect(replacement.identity != original.identity)
        do {
            _ = try await original.submitDurably(ChatMessage(role: .user, text: "Old owner"))
            Issue.record("A retired owner must not acknowledge an unpersisted submission")
        } catch is CancellationError { }
        let current = try await replacement.submitDurably(ChatMessage(role: .user, text: "New owner"))
        #expect(current.messages.map(\.text) == ["New owner"])
        await registry.invalidate(threadID: "thread")
    }

    @Test func observationRejectsPreAckDeliveryEvenAfterCatchUpFinishes() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread", checkpoints: ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
        let capture = UUID(), connection = UUID()
        let prefix = CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn",
            item: .agentMessage(id: "answer", text: "before "), isComplete: false)
        let checkpoint = CodexAppServerV2.ThreadObservationCheckpoint(turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil, activeTurn: nil, historyUnavailable: false, liveItems: [prefix])
        let header = history(items: []).header
        await session.beginObservation(capture)
        try await session.finishObservation(capture, receipt: .init(connection: connection, sequence: 10),
            header: header, checkpoint: checkpoint,
            history: .init(turns: [], entries: [], update: nil), read: await session.beginHistoryRead())
        for (sequence, text, socket) in [(9, "before ", connection), (100, "obsolete ", UUID()), (11, "after", connection)] {
            let note = GatewayEventFixture.notification(method: "item/agentMessage/delta", params: .object([
                "threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("answer"), "delta": .string(text)
             ]), receipt: .init(connection: socket, sequence: UInt64(sequence)))
            guard case .turnEvent(let event) = try #require(GatewayNotificationRouting.route(note)) else { throw GatewayEventFixture.Failure.invalidEvent }
            await session.ingest(event, replay: false)
        }
        #expect(await session.snapshot().messages.map(\.text) == ["before after"])
    }

    @Test(.timeLimit(.minutes(1))) func observationPublishesWithoutAnotherLiveEventAndPreservesAFarBackWindow() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread", checkpoints: ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
        let initial = measured(entries([.agentMessage(id: "initial", text: "Initial")], turnID: "initial-turn"), older: "before-initial",
            placement: .tail, base: nil)
        _ = await session.merge(initial)
        let capture = UUID()
        await session.beginObservation(capture)
        _ = await session.merge(measured([.init(turnId: "older-turn", item: .agentMessage(id: "older", text: "Viewed history"), isComplete: true)],
            older: nil, placement: .older("before-initial"), base: await session.beginHistoryRead().base))
        let stream = await session.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let checkpoint = CodexAppServerV2.ThreadObservationCheckpoint(turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil, activeTurn: nil, historyUnavailable: false, liveItems: [
                .init(turnId: "initial-turn", item: .agentMessage(id: "new", text: "Recovered"), isComplete: false)
            ])
        try await session.finishObservation(capture, receipt: .init(connection: UUID(), sequence: 10),
            header: initial.header, checkpoint: checkpoint,
            history: .init(turns: [summary("initial-turn")], entries: [], update: initial.update), read: await session.beginHistoryRead())
        let published = try #require(await iterator.next())
        #expect(await session.beginHistoryRead().base?.turns.map(\.id) == ["older-turn"])
        #expect(published.messages.map(\.text) == ["Viewed history"])
        let returned = await session.merge(.fixture(wire: entries([.agentMessage(id: "initial", text: "Initial")], turnID: "initial-turn"),
            turns: [summary("initial-turn")], placement: .reset))
        #expect(returned.messages.map(\.text) == ["Initial", "Recovered"])
    }

    @Test func flushPersistsStreamedTextThatNoCompletionHasSaved() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let id = UUID()
        let session = await ConversationSession.make(conversationID: id, threadID: "thread",
            checkpoints: ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024))
        await session.ingest(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1), replay: false)
        try await session.flush()
        await session.ingest(try agentDelta("Streamed before backgrounding"), replay: false)
        try await session.flush()
        let cold = await ConversationSession.make(conversationID: id, threadID: "thread",
            checkpoints: ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024))
        try await cold.restore()
        #expect(await cold.snapshot().messages.map(\.text) == ["Streamed before backgrounding"])
    }

    @Test(.timeLimit(.minutes(1))) func streamedDeltasPublishOncePerIntervalAndTheirCompletionAlwaysPublishes() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread",
            checkpoints: ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024))
        await session.ingest(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1), replay: false)
        let stream = await session.snapshots()
        let published = Task {
            var count = 0
            var partial = 0
            for await snapshot in stream {
                count += 1
                guard let answer = snapshot.messages.last else { continue }
                if !answer.isStreaming { return (count, partial, answer.text) }
                if !answer.text.isEmpty { partial += 1 }
            }
            return (count, partial, "")
        }
        let clock = ContinuousClock()
        let start = clock.now
        var text = ""
        for index in 0..<40 {
            text += "word\(index) "
            await session.ingest(try agentDelta("word\(index) "), replay: false)
            try await Task.sleep(for: .milliseconds(5))
        }
        let streamed = start.duration(to: clock.now)
        await session.ingest(try event("item/completed", item: .agentMessage(id: "answer", text: text), ordinal: 1), replay: false)
        let (publications, partial, final) = await published.value
        #expect(final == text)
        #expect(partial > 0)
        #expect(publications <= 4 + Int(streamed / ConversationSession.streamingPublicationInterval))
    }
}
