import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationStateTests: ConversationHistoryFixtures {
    @Test func deliveryEvidenceRespectsTheLiveByteBudgetAndRetainsOneOversizedItem() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: entries([.agentMessage(id: "old", text: "Older history")], turnID: "old"),
            older: "older", newer: "newer", placement: .reset))
        var canonical: [CodexAppServerV2.ThreadItem] = []
        for index in 0..<2 {
            let message = ChatMessage(role: .user, text: "Input", wasSteered: true, canonicalTurnID: "live")
            state.submit(message)
            state.submissionFailed(message.id, failure: .uncertain("Connection lost"))
            canonical.append(.userMessage(id: "canonical-\(index)", content: [.text(text: String(repeating: "x", count: 3 * 1_024 * 1_024), textElements: [])], clientId: message.id.uuidString))
        }
        state.reconcileDeliveryEvidence(history(items: canonical, turnID: "live"))
        #expect(state.submissions.isEmpty)
        #expect(state.turns["live"]?.order == ["canonical-1"])
        #expect(state.turns["live"]?.items["canonical-1"]?.encodedBytes ?? 0 > 3 * 1_024 * 1_024)
        let message = ChatMessage(role: .user, text: "Large input", wasSteered: true, canonicalTurnID: "live")
        state.submit(message)
        state.submissionFailed(message.id, failure: .uncertain("Connection lost"))
        let oversized = CodexAppServerV2.ThreadItem.userMessage(id: "oversized", content: [.text(text: String(repeating: "x", count: 5 * 1_024 * 1_024), textElements: [])], clientId: message.id.uuidString)
        state.reconcileDeliveryEvidence(history(items: [oversized], turnID: "live"))
        #expect(state.turns["live"]?.order == ["oversized"])
        #expect(state.turns["live"]?.items["oversized"]?.encodedBytes ?? 0 > 4 * 1_024 * 1_024)
    }

    @Test func deliveryEvidenceCannotImportUnrelatedHistoryOrClearANewerTerminalError() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object([
            "id": .string("live"), "status": .string("failed"), "error": .object(["message": .string("New failure explanation")])
        ])]), method: "turn/completed"))
        #expect(state.turns["live"]?.terminalError == "New failure explanation")
        let message = ChatMessage(role: .user, text: "Repeat", wasSteered: true, canonicalTurnID: "live")
        state.submit(message)
        state.submissionFailed(message.id, failure: .uncertain("Connection lost"))
        let metadata = CodexAppServerV2.Turn(id: "live", items: [], startedAt: 1, completedAt: 2, status: .failed, error: nil)
        let unrelated = CodexAppServerV2.ThreadItem.agentMessage(id: "unrelated", text: "Old transcript")
        let before = state.turns.dictionary
        let order = state.order
        let revision = state.persistenceRevision
        let unmatchedChanged = state.reconcileDeliveryEvidence(.fixture(wire: entries([unrelated], turnID: "live"), turns: [metadata]))
        #expect(!unmatchedChanged)
        #expect(state.turns.dictionary == before)
        #expect(state.order == order)
        #expect(state.persistenceRevision == revision)
        let canonical = CodexAppServerV2.ThreadItem.userMessage(id: "canonical", content: [.text(text: "Repeat", textElements: [])], clientId: message.id.uuidString)
        let matchedChanged = state.reconcileDeliveryEvidence(.fixture(wire: entries([unrelated, canonical], turnID: "live"), turns: [metadata]))
        #expect(matchedChanged)
        #expect(state.turns["live"]?.terminalError == "New failure explanation")
        #expect(state.turns["live"]?.items["unrelated"] == nil)
        #expect(state.turns["live"]?.items["canonical"]?.localMessage?.id == message.id)
    }

    @Test func deliveryEvidenceConfirmsOnlyExactClientIdentityWithoutMovingTheBrowsingWindow() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: entries([.agentMessage(id: "old", text: "Older history")], turnID: "old"),
            older: "older", newer: "newer", placement: .reset))
        let browsing = try #require(state.window)
        let message = ChatMessage(role: .user, text: "Repeat", wasSteered: true, canonicalTurnID: "live")
        state.submit(message)
        state.submissionFailed(message.id, failure: .uncertain("Connection lost"))
        let unrelated = CodexAppServerV2.ThreadItem.userMessage(id: "unrelated", content: [.text(text: "Repeat", textElements: [])], clientId: UUID().uuidString)
        state.reconcileDeliveryEvidence(history(items: [unrelated], turnID: "live"))
        #expect(state.submissions[message.id]?.status == .uncertain)
        let canonical = CodexAppServerV2.ThreadItem.userMessage(id: "canonical", content: [.text(text: "Repeat", textElements: [])], clientId: message.id.uuidString)
        state.reconcileDeliveryEvidence(history(items: [canonical], turnID: "live"))
        #expect(state.submissions.isEmpty)
        #expect(state.window?.older == browsing.older)
        #expect(state.window?.newer == browsing.newer)
        #expect(state.window?.turns.map(\.id) == browsing.turns.map(\.id))
        #expect(state.turns["live"]?.items["canonical"]?.localMessage?.id == message.id)
    }

    @Test func voiceHandoffsDisplayTheirInputAndKeepTheCanonicalEnvelope() throws {
        let envelope = "<realtime_delegation><input>Compare a &lt; b &amp;&amp; c &gt; d</input><transcript_delta>user: compare them</transcript_delta></realtime_delegation>"
        let item = CodexAppServerV2.ThreadItem.userMessage(id: "handoff", content: [.text(text: envelope, textElements: [])])
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/completed", item: item, ordinal: 1))
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["Compare a < b && c > d"])
        if case .userMessage(_, let content, _) = state.turns["turn"]?.items["handoff"]?.value,
           case .text(let stored, _) = content.first {
            #expect(stored == envelope)
        } else { Issue.record("The canonical handoff must remain intact") }
        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(state.checkpoint)
        #expect(ConversationProjection.project(restored).messages.map(\.text) == ["Compare a < b && c > d"])
    }

    @Test func voiceTranscriptFlushBecomesAnActivityInsteadOfAnInstructionBubble() throws {
        let envelope = """
        <realtime_delegation>
          <source>transcript_tail_flush</source>
          <input>The user just ended their realtime session. Acknowledge the handoff.</input>
          <transcript_delta>user: Hello\nassistant: How's it going?</transcript_delta>
        </realtime_delegation>
        """
        let item = CodexAppServerV2.ThreadItem.userMessage(id: "tail", content: [.text(text: envelope, textElements: [])])
        var live = ConversationState(conversationID: UUID(), threadID: "thread")
        live.apply(try event("item/completed", item: item, ordinal: 1))
        var replay = ConversationState(conversationID: live.conversationID, threadID: "thread")
        replay.merge(history(items: [item]))
        for state in [live, replay] {
            let snapshot = ConversationProjection.project(state)
            #expect(snapshot.messages.isEmpty)
            let activity = try #require(snapshot.timelines.first?.events.first)
            #expect(activity.title == "Voice conversation ended")
            #expect(activity.details.map(\.value) == ["user: Hello\nassistant: How's it going?"])
        }
    }

    @Test func literalAndMalformedVoiceEnvelopesRemainVisible() throws {
        let literal = "<realtime_delegation><input>Example</input></realtime_delegation>"
        let authored = ChatMessage(role: .user, text: literal)
        var local = ConversationState(conversationID: UUID(), threadID: "thread")
        local.submit(authored)
        #expect(ConversationProjection.project(local).messages.map(\.text) == [literal])

        var authoredReplay = ConversationState(conversationID: UUID(), threadID: "thread")
        authoredReplay.merge(history(items: [.userMessage(id: "authored", content: [.text(text: literal, textElements: [])], clientId: authored.id.uuidString)]))
        #expect(ConversationProjection.project(authoredReplay).messages.map(\.text) == [literal])

        let unknownSource = "<realtime_delegation><source>unknown</source><input>Example</input></realtime_delegation>"
        var replayed = ConversationState(conversationID: UUID(), threadID: "thread")
        replayed.apply(try event("item/completed", item: .userMessage(id: "user", content: [.text(text: unknownSource, textElements: [])]), ordinal: 1))
        #expect(ConversationProjection.project(replayed).messages.map(\.text) == [unknownSource])
    }

    @Test func theTranscriptKeepsTheNewestFinishedTurnItWasGiven() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        #expect(state.lastTurnCompletedAt == nil)
        let read = history(items: [])
        state.merge(headed(read, lastTurnCompletedAt: 200))
        state.merge(headed(read, lastTurnCompletedAt: 100))
        #expect(state.lastTurnCompletedAt == 200)

        state.merge(.fixture(wire: entries([.agentMessage(id: "done", text: "Done")], turnID: "finished"), turns: [finishedTurn(at: 250)]))
        #expect(state.lastTurnCompletedAt == 250)

        let saved = try JSONDecoder().decode(ConversationState.Checkpoint.self, from: JSONEncoder().encode(state.checkpoint))
        var reopened = ConversationState(conversationID: UUID(), threadID: "thread")
        reopened.restore(saved)
        #expect(reopened.lastTurnCompletedAt == 250)
    }

    @Test func claudeReadsTakeTheHeaderTimeAndIgnoreProjectedTurns() throws {
        var claude = ConversationState(conversationID: UUID(), threadID: "claude_thread")
        let read = GatewayHistoryService.ConversationSnapshot.fixture(threadID: "claude_thread",
            wire: entries([.agentMessage(id: "done", text: "Done")], turnID: "finished", ordered: false), turns: [finishedTurn(at: 300)])
        claude.merge(read)
        #expect(claude.lastTurnCompletedAt == nil)
        claude.merge(headed(read, lastTurnCompletedAt: 150))
        #expect(claude.lastTurnCompletedAt == 150)

        claude.apply(try GatewayEventFixture.turn(.object(["threadId": .string("claude_thread"), "turn": .object([
            "id": .string("turn"), "status": .string("completed"), "completedAt": .number(160),
        ])]), method: "turn/completed"))
        #expect(claude.lastTurnCompletedAt == 160)
    }

    @Test(arguments: [false, true])
    func acceptedOrUncertainMessageSurvivesEmptyPageAndReconcilesByClientIdentity(acknowledged: Bool) throws {
        let message = ChatMessage(role: .user, text: "Run the tests")
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.submit(message)
        if acknowledged {
            state.accepted(message.id, turnID: "turn")
        } else {
            let failure = ConversationState.SubmissionFailure.uncertain("The data couldn't be read because it isn't in the correct format.")
            state.submissionFailed(message.id, failure: failure)
            #expect(failure.userMessage.contains("may have arrived"))
            #expect(!failure.userMessage.contains("correct format"))
        }
        state.merge(history(items: []))
        #expect(ConversationProjection.project(state).messages.map(\.id) == [message.id])
        let canonical = CodexAppServerV2.ThreadItem.userMessage(id: "server-user", content: [.text(text: message.text, textElements: [])], clientId: message.id.uuidString)
        if acknowledged { state.apply(try event("item/completed", item: canonical, ordinal: 1)) }
        else { state.merge(history(items: [canonical])) }
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.messages.map(\.id) == [message.id])
        #expect(snapshot.messages.first?.canonicalItemID == "server-user")
        #expect(state.submissions.isEmpty)
        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(state.checkpoint)
        #expect(ConversationProjection.project(restored).messages == snapshot.messages)
    }

    /// A Claude history read taken before the gateway echoed the prompt labels it
    /// with a turn id the gateway synthesized and no client identity. Adopting
    /// that label as a second turn renders the same submission twice.
    @Test func claudeHistoryCannotRelabelALiveTurnIntoASecondUserBubble() throws {
        let message = ChatMessage(role: .user, text: "great also a biiit less toward black/white")
        var state = ConversationState(conversationID: UUID(), threadID: "claude_thread")
        state.submit(message)
        state.accepted(message.id, turnID: "claude-turn-1789856966285-26")
        let unrecorded = CodexAppServerV2.ThreadItem.userMessage(
            id: message.id.uuidString,
            content: [.text(text: message.text, textElements: [])],
            clientId: nil)
        state.merge(claudeHistory(items: [unrecorded], turnID: "claude-turn-30"))
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.messages.map(\.id) == [message.id])
        #expect(snapshot.messages.map(\.text) == [message.text])
        #expect(state.order == ["claude-turn-1789856966285-26"])
    }

    /// Two gateway restarts each resumed a Claude turn and the user steered both.
    /// An earlier read had filed an unindexed row under the running recovery turn,
    /// and a later read named that row's turn differently; adopting the alias's
    /// position put the live recovery turn ahead of the one before it.
    @Test func aClaudeHistoryAliasCannotMoveARecoveredTurnAheadOfEarlierTurns() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "claude_thread")
        let reply = { (id: String) in CodexAppServerV2.ThreadItem.agentMessage(id: id, text: id) }
        let steer = { (id: String) in CodexAppServerV2.ThreadItem.userMessage(id: id, content: [.text(text: id, textElements: [])], clientId: id) }
        let interrupted = ("claude-turn-1790200612990-23", [steer("PROMPT"), reply("m1#0")])
        let firstRecovery = ("claude-turn-1790201604265-4", [reply("m2#0"), steer("STEER-1"), reply("m3#0")])
        let secondRecovery = ("claude-turn-1790202564261-5", [reply("stale#0"), reply("m4#0"), steer("STEER-2"), reply("m5#0")])
        state.merge(claudeHistory(turns: [interrupted, secondRecovery, firstRecovery]))
        #expect(state.order == [interrupted.0, secondRecovery.0, firstRecovery.0])

        state.merge(claudeHistory(turns: [interrupted, ("claude-turn-30", [reply("stale#0")]), firstRecovery,
                                          (secondRecovery.0, [reply("m4#0"), steer("STEER-2"), reply("m5#0")])]))
        #expect(state.order == [interrupted.0, firstRecovery.0, secondRecovery.0])
        #expect(ConversationProjection.project(state).messages.filter { $0.role == .user }.map(\.text) == ["PROMPT", "STEER-1", "STEER-2"])
    }

    @Test func identicalSubmissionsRemainDistinctUntilTheirOwnAcknowledgements() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let first = ChatMessage(role: .user, text: "Yes")
        let second = ChatMessage(role: .user, text: "Yes", wasSteered: true)
        state.submit(first); state.submit(second)
        state.accepted(first.id, turnID: "turn"); state.accepted(second.id, turnID: "turn")
        state.apply(try event("item/completed", item: .userMessage(id: "second", content: [.text(text: "Yes", textElements: [])], clientId: second.id.uuidString), ordinal: 2))
        #expect(Set(state.submissions.keys) == [first.id])
        #expect(Set(ConversationProjection.project(state).messages.map(\.id)) == [first.id, second.id])
    }

    @Test(arguments: [false, true])
    func toolCompletionPreservesItsStartPositionAndMessagesSplitGroups(reverseCompletion: Bool) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let first = tool("first", status: .inProgress)
        let second = tool("second", status: .inProgress)
        let message = CodexAppServerV2.ThreadItem.agentMessage(id: "progress", text: "Build succeeded")
        state.apply(try event("item/started", item: first, ordinal: 10))
        state.apply(try event("item/completed", item: message, ordinal: 20))
        state.apply(try event("item/started", item: second, ordinal: 30))
        let completion = [try event("item/completed", item: tool("first", status: .completed), ordinal: 10),
                          try event("item/completed", item: tool("second", status: .completed), ordinal: 30)]
        for event in reverseCompletion ? completion.reversed() : completion { state.apply(event) }
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.items.map(\.id) == ["timeline-gw-thread-turn-seg-start", "message-\(snapshot.messages[0].id)", "timeline-gw-thread-turn-seg-\(snapshot.messages[0].id)"])
        #expect(snapshot.timelines.map { $0.events.map(\.id) } == [["gw-thread-turn-first"], ["gw-thread-turn-second"]])
        let before = snapshot.items
        state.apply(completion[0]); state.apply(completion[1])
        #expect(ConversationProjection.project(state).items == before)
    }

    @Test func aViewedImageSplitsTheActionGroupWithoutCountingAsAReply() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: tool("first", status: .completed), ordinal: 10))
        state.apply(try event("item/completed", item: .imageView(
            id: "view", path: "/tmp/chart.png", image: .init(path: "/media/abc.png", mimeType: "image/png")), ordinal: 20))
        state.apply(try event("item/started", item: tool("second", status: .completed), ordinal: 30))
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.items.map(\.id) == ["timeline-gw-thread-turn-seg-start", "viewed-media-view-0",
                                             "timeline-gw-thread-turn-seg-viewed-media-view-0"])
        #expect(snapshot.items[1] == .viewedMedia(ViewedMedia(itemID: "view", index: 0, path: "/media/abc.png",
                                                              caption: "chart.png")))
        #expect(snapshot.timelines.map { $0.events.map(\.id) } == [["gw-thread-turn-first"], ["gw-thread-turn-second"]])
        #expect(snapshot.messages.isEmpty)
    }

    @Test func toolMediaFollowsItsToolCallAndSplitsTheActionGroup() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let screenshot = CodexAppServerV2.ThreadItem.mcpToolCall(
            id: "shot", server: "chrome", tool: "take_screenshot", status: .completed, arguments: .object([:]),
            result: nil, error: nil, durationMs: nil,
            media: [.init(path: "/s/a.png", mimeType: "image/png"),
                    .init(path: "/tmp/report.pdf", mimeType: "application/pdf", name: "report.pdf")])
        state.apply(try event("item/started", item: tool("first", status: .completed), ordinal: 10))
        state.apply(try event("item/completed", item: screenshot, ordinal: 20))
        state.apply(try event("item/started", item: tool("second", status: .completed), ordinal: 30))
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.items.map(\.id) == ["timeline-gw-thread-turn-seg-start", "viewed-media-shot-0", "viewed-media-shot-1",
                                             "timeline-gw-thread-turn-seg-viewed-media-shot-1"])
        #expect(snapshot.items[1] == .viewedMedia(ViewedMedia(itemID: "shot", index: 0, path: "/s/a.png",
                                                              caption: "take_screenshot")))
        #expect(snapshot.items[2] == .viewedMedia(ViewedMedia(itemID: "shot", index: 1, path: "/tmp/report.pdf",
                                                              caption: "report.pdf")))
        #expect(snapshot.timelines.map { $0.events.map(\.id) } == [["gw-thread-turn-first", "gw-thread-turn-shot"],
                                                                    ["gw-thread-turn-second"]])
    }

    @Test func steeringIsABoundaryInLiveAndReloadedHistory() throws {
        let steer = CodexAppServerV2.ThreadItem.userMessage(id: "steer", content: [.text(text: "Also run the lint checks", textElements: [])])
        let items: [CodexAppServerV2.ThreadItem] = [
            .userMessage(id: "user", content: [.text(text: "Build", textElements: [])]),
            tool("first", status: .completed),
            .agentMessage(id: "progress", text: "The build passed"),
            steer, tool("second", status: .completed),
            .agentMessage(id: "answer", text: "The lint checks passed too")
        ]
        var live = ConversationState(conversationID: UUID(), threadID: "thread")
        for (ordinal, item) in items.enumerated() { live.apply(try event("item/completed", item: item, ordinal: ordinal)) }
        var historyState = ConversationState(conversationID: live.conversationID, threadID: "thread")
        historyState.merge(history(items: items))
        #expect(ConversationProjection.project(live).items.map(\.id) == ConversationProjection.project(historyState).items.map(\.id))
        var restored = ConversationState(conversationID: live.conversationID, threadID: "thread")
        restored.restore(live.checkpoint)
        for state in [live, historyState, restored] {
            #expect(ConversationProjection.project(state).messages.map(\.wasSteered) == [false, false, true, false])
            #expect(ConversationProjection.project(state).messages.map(\.delivery) == [nil, nil, .steered, nil])
        }
        #expect(ConversationProjection.project(live).timelines.count == 2)
    }

    @Test func replayDoesNotDuplicateDeltasAndTerminalStateDoesNotRegress() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1))
        let delta = try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turnId": .string("turn"),
            "itemId": .string("answer"), "delta": .string("Hello")]), method: "item/agentMessage/delta")
        state.apply(delta); state.apply(delta, replay: true)
        #expect(ConversationProjection.project(state).messages.first?.text == "Hello")
        state.apply(try event("item/completed", item: .agentMessage(id: "answer", text: "Hello world"), ordinal: 1))
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])]), method: "turn/completed"))
        state.apply(delta)
        state.activity(turnID: "turn", active: true)
        #expect(ConversationProjection.project(state).messages.first?.text == "Hello world")
        #expect(state.turns["turn"]?.isActive == true)
    }

    @Test func aFailedTurnAndAnEmptyCompletedReplyShowTheirOutcome() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try lifecycle("turn/started", turnID: "failed", status: "inProgress"))
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object([
            "id": .string("failed"), "status": .string("failed"), "error": .object(["message": .string("Quota exhausted")])])]),
            method: "turn/completed"))
        state.apply(try lifecycle("turn/started", turnID: "empty", status: "inProgress"))
        state.apply(try lifecycle("turn/completed", turnID: "empty", status: "completed"))
        state.apply(try lifecycle("turn/started", turnID: "answered", status: "inProgress"))
        state.apply(try itemEvent("item/completed", .agentMessage(id: "answer", text: "Done"), turnID: "answered", ordinal: 1))
        state.apply(try lifecycle("turn/completed", turnID: "answered", status: "completed"))
        func outcomes(_ state: ConversationState) -> [TurnOutcome] {
            ConversationProjection.project(state).items.compactMap { if case .turnOutcome(let outcome) = $0 { outcome } else { nil } }
        }
        #expect(outcomes(state).map(\.turnID).sorted() == ["empty", "failed"])
        #expect(outcomes(state).first { $0.turnID == "failed" }?.kind == .failed(message: "Quota exhausted"))
        #expect(outcomes(state).first { $0.turnID == "empty" }?.kind == .noReply)
        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(state.checkpoint)
        #expect(outcomes(restored) == outcomes(state))
    }

    @Test func olderOrIncompleteHistoryCannotReplaceStreamedOrDetailedContent() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: .agentMessage(id: "answer", text: "New streaming content"), ordinal: 1))
        let incomplete = GatewayHistoryService.ConversationSnapshot.fixture(wire: [.init(turnId: "turn",
            item: .agentMessage(id: "answer", text: "Old"), startedAtOrdinal: 1, startedAtMs: 1000, isComplete: false)], turns: [summary("turn")])
        state.merge(incomplete)
        #expect(ConversationProjection.project(state).messages.first?.text == "New streaming content")
        state.apply(try event("item/completed", item: .agentMessage(id: "answer", text: "Final answer"), ordinal: 1))
        state.merge(incomplete)
        state.merge(.fixture(wire: [.init(turnId: "turn", item: .agentMessage(id: "answer", text: "Old"), startedAtOrdinal: 1,
            startedAtMs: 1000, completedAtMs: 1000, isComplete: true)], turns: [summary("turn")]))
        #expect(ConversationProjection.project(state).messages.first?.text == "Final answer")
    }

    @Test func anOlderPageAddsItsTurnBeneathTheTail() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: entries([.agentMessage(id: "b", text: "Second")], turnID: "b"), turns: [summary("b"), summary("a")],
            older: "before-b"))
        #expect(ConversationProjection.project(state).items.first?.id == "history-edge-older")
        state.merge(.fixture(wire: entries([.agentMessage(id: "a", text: "First")], turnID: "a"), placement: .older("before-b"),
            base: state.window))
        #expect(state.window?.turns.map(\.id) == ["a", "b"])
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["First", "Second"])
        state.merge(.fixture(wire: entries([.agentMessage(id: "stale", text: "Stale")], turnID: "stale"), placement: .older("before-b"),
            base: state.window))
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["First", "Second"])
    }

    @Test func readingOlderPastTheBudgetDropsTheNewestTurnFromTheTranscript() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(measured(entries([.agentMessage(id: "b", text: "Second")], turnID: "b"), older: "before-b", placement: .tail, base: nil))
        state.merge(measured(entries([.agentMessage(id: "a", text: "First")], turnID: "a"), older: nil, placement: .older("before-b"),
            base: state.window))
        #expect(state.window?.turns.map(\.id) == ["a"])
        #expect(state.window?.newerEdge != nil)
        #expect(state.turns["b"]?.items.isEmpty == true)
        #expect(ConversationProjection.project(state).messages.map(\.canonicalItemID) == ["a"])
    }

    @Test func laterCompletionRefreshesContentWithoutMovingAndOlderReplayCannotUndoIt() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let old = try event("item/completed", item: .agentMessage(id: "answer", text: "Initial result"), ordinal: 1)
        state.apply(old)
        state.merge(.fixture(wire: [.init(turnId: "turn", item: .agentMessage(id: "answer", text: "Final result"), startedAtOrdinal: 1,
            startedAtMs: 1000, completedAtMs: 3000, isComplete: true)], turns: [summary("turn")]))
        state.apply(old, replay: true)
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["Final result"])
        #expect(state.turns["turn"]?.items["answer"]?.position == 1)
    }

    @Test func aQueuedSteerLeavesRunningWorkLiveUntilTheAgentTakesIt() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.activity(turnID: "turn", active: true)
        state.apply(try event("item/completed", item: .userMessage(id: "original", content: [.text(text: "Start", textElements: [])]), ordinal: 0))
        state.apply(try event("item/started", item: tool("tool", status: .inProgress), ordinal: 1))
        let steer = ChatMessage(role: .user, text: "Steer", wasSteered: true, canonicalTurnID: "turn")
        state.submit(steer)
        let submitted = ConversationProjection.project(state).items.map(\.id)
        state.accepted(steer.id, turnID: "turn")

        let queued = ConversationProjection.project(state)
        #expect(queued.items.map(\.id) == submitted)
        #expect(queued.timelines.map(\.isLive) == [true])
        #expect(queued.timelines.first?.events.count == 1)
        #expect(queued.items.last?.id == "message-\(steer.id.uuidString)")
        #expect(queued.messages.last?.id == steer.id)
        #expect(queued.messages.last?.delivery == .pendingSteer)

        state.apply(try event("item/completed", item: tool("tool", status: .completed), ordinal: 1))
        let id = steer.id.uuidString
        state.apply(try event("item/completed", item: .userMessage(id: id, content: [.text(text: "Steer", textElements: [])], clientId: id),
                              ordinal: 2, completedAtMs: 600_000))
        let delivered = ConversationProjection.project(state)
        #expect(delivered.messages.map(\.id).last == steer.id)
        #expect(delivered.messages.last?.delivery == .steered)
        #expect(delivered.timelines.map(\.isLive) == [false, true])
        #expect(delivered.timelines.first?.completedAt == Date(timeIntervalSince1970: 600))
        #expect(delivered.timelines.last?.startedAt == Date(timeIntervalSince1970: 600))
    }

    @Test func aSteerTheAgentNeverTookDoesNotReadAsSteered() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.activity(turnID: "turn", active: true)
        state.apply(try event("item/completed", item: .userMessage(id: "original", content: [.text(text: "Start", textElements: [])]), ordinal: 0))
        let rejected = ChatMessage(role: .user, text: "Rejected", wasSteered: true, canonicalTurnID: "turn")
        let dropped = ChatMessage(role: .user, text: "Dropped", wasSteered: true, canonicalTurnID: "turn")
        state.submit(rejected)
        state.submit(dropped)
        state.accepted(dropped.id, turnID: "turn")
        var memo = ConversationProjection.Memo()
        let queued = ConversationProjection.project(state, memo: &memo).messages
        #expect(queued.map(\.delivery) == [nil, .pendingSteer, .pendingSteer])

        state.submissionFailed(rejected.id, failure: .rejected("The turn is busy."))
        let failed = ConversationProjection.project(state, memo: &memo).messages
        #expect(failed.first { $0.id == rejected.id }?.delivery == .notSent)

        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"),
            "turn": .object(["id": .string("turn"), "status": .string("interrupted")])]), method: "turn/completed"))
        let ended = ConversationProjection.project(state, memo: &memo).messages
        #expect(ended.first { $0.id == dropped.id }?.delivery == .unconfirmed)
        #expect(ended.first { $0.id == rejected.id }?.delivery == .notSent)
    }

    @Test func aSentMessageReadsSendingUntilTheGatewayAcceptsIt() {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let sent = ChatMessage(role: .user, text: "Sent")
        let lost = ChatMessage(role: .user, text: "Lost")
        state.submit(sent)
        state.submit(lost)
        var memo = ConversationProjection.Memo()
        #expect(ConversationProjection.project(state, memo: &memo).messages.map(\.delivery) == [.sending, .sending])

        state.accepted(sent.id, turnID: "turn")
        state.submissionFailed(lost.id, failure: .uncertain("The connection closed."))
        let settled = ConversationProjection.project(state, memo: &memo).messages
        #expect(settled.first { $0.id == sent.id }?.delivery == nil)
        #expect(settled.first { $0.id == lost.id }?.delivery == .unconfirmed)
    }

    @Test func aStoppedTurnHandsItsDiscardedSteersOnAsOneMessage() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.activity(turnID: "turn", active: true)
        state.apply(try event("item/completed", item: .userMessage(id: "original", content: [.text(text: "Start", textElements: [])]), ordinal: 0))
        let unconfirmedOriginal = ChatMessage(role: .user, text: "Unconfirmed original")
        state.submit(unconfirmedOriginal)
        state.accepted(unconfirmedOriginal.id, turnID: "turn")
        let pasted = MessageAttachment(id: UUID(), content: .text("pasted log"))
        func steer(_ text: String, attachments: [MessageAttachment] = []) -> ChatMessage {
            ChatMessage(role: .user, text: text, attachments: attachments, wasSteered: true, canonicalTurnID: "turn")
        }
        let taken = steer("Taken"), first = steer("wait lower volume!", attachments: [pasted]), second = steer("on TV")
        let inFlight = steer("In flight")
        for message in [taken, first, second, inFlight] { state.submit(message, input: "prompt: \(message.text)") }
        for message in [taken, first, second] { state.accepted(message.id, turnID: "turn") }
        let takenID = taken.id.uuidString
        state.apply(try event("item/completed", item: .userMessage(id: takenID, content: [.text(text: "prompt: Taken", textElements: [])],
                                                                    clientId: takenID), ordinal: 1))
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"),
            "turn": .object(["id": .string("turn"), "status": .string("interrupted")])]), method: "turn/completed"))

        let continuation = state.takeDiscardedSteers(of: "turn")
        let merged = try #require(continuation)
        #expect(merged.input == "prompt: wait lower volume!\nprompt: on TV")
        #expect(merged.message.text == "wait lower volume!\non TV")
        #expect(merged.message.attachments.map(\.id) == [pasted.id])
        #expect(merged.status == .submitting)
        let ids = Set(ConversationProjection.project(state).messages.map(\.id))
        #expect(ids.isSuperset(of: [unconfirmedOriginal.id, taken.id, inFlight.id, merged.message.id]))
        #expect(ids.isDisjoint(with: [first.id, second.id]))
        let retaken = state.takeDiscardedSteers(of: "turn")
        #expect(retaken == nil)

        var single = ConversationState(conversationID: UUID(), threadID: "thread")
        single.activity(turnID: "turn", active: true)
        single.submit(unconfirmedOriginal)
        single.accepted(unconfirmedOriginal.id, turnID: "turn")
        #expect(single.takeDiscardedSteers(of: "turn") == nil)
        let only = steer("Only")
        single.submit(only)
        single.accepted(only.id, turnID: "turn")
        let revision = single.persistenceRevision
        let unchanged = single.takeDiscardedSteers(of: "turn")
        #expect(unchanged?.message.id == only.id)
        #expect(single.persistenceRevision == revision)
    }

    @Test func restoringAPendingCheckpointAfterCanonicalDeliveryDoesNotDuplicateTheUser() throws {
        var pending = ConversationState(conversationID: UUID(), threadID: "thread")
        let message = ChatMessage(role: .user, text: "Restore")
        pending.submit(message)
        var live = ConversationState(conversationID: pending.conversationID, threadID: "thread")
        live.apply(try event("item/completed", item: .userMessage(id: "canonical", content: [.text(text: message.text, textElements: [])], clientId: message.id.uuidString), ordinal: 1))
        live.restore(pending.checkpoint)
        #expect(ConversationProjection.project(live).messages.map(\.id) == [message.id])
        #expect(live.submissions.isEmpty)
    }

    @Test func persistedRunningStatusDoesNotEstablishRuntimeActivity() {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [tool("tool", status: .inProgress)]))
        #expect(ConversationProjection.project(state).timelines.allSatisfy { !$0.isLive })
    }

    @Test func agentDeltasAreStreamingUntilItemCompletion() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: .agentMessage(id: "agent", text: "Hi"), ordinal: 1))
        #expect(ConversationProjection.project(state).messages.first?.isStreaming == true)
        state.apply(try event("item/completed", item: .agentMessage(id: "agent", text: "Hi there"), ordinal: 1))
        #expect(ConversationProjection.project(state).messages.first?.isStreaming == false)
        state.apply(try event("item/started", item: .userMessage(id: "user", content: [.text(text: "Next", textElements: [])]), ordinal: 2))
        #expect(ConversationProjection.project(state).messages.last?.isStreaming == false)
    }

    @Test func runtimeTurnAliasesDoNotCreateASecondTranscriptTurn() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn-1"), "status": .string("inProgress")])]), method: "turn/started"))
        state.activity(turnID: "1", active: true)
        #expect(state.order == ["turn-1"])
    }

    @Test(arguments: ["thread", "claude_thread"])
    func aLongLiveTurnRetainsABoundedTailAndAReloadEdge(threadID: String) throws {
        var state = ConversationState(conversationID: UUID(), threadID: threadID)
        state.merge(history(items: [], threadID: threadID))
        let pending = ChatMessage(role: .user, text: "Keep my submission")
        state.submit(pending); state.accepted(pending.id, turnID: "turn")
        for index in 0..<450 {
            state.apply(try event("item/completed", item: .agentMessage(id: "m-\(index)", text: "Message \(index)"), ordinal: index,
                threadID: threadID))
        }
        let snapshot = ConversationProjection.project(state)
        #expect(state.turns["turn"]?.items.count == 201)
        #expect(snapshot.messages.contains { $0.id == pending.id })
        #expect(snapshot.items.contains { $0.id == HistoryEdge(kind: .reload(turnID: "turn"), cursor: nil).id })
    }

    @Test func aFarBackWindowDoesNotMixAnUncoveredLiveTailIntoItsPage() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/completed", item: .agentMessage(id: "latest", text: "Live tail"), ordinal: 200))
        state.merge(farBack([.init(turnId: "turn", item: .agentMessage(id: "old", text: "Older page"), startedAtOrdinal: 0, isComplete: true)]))
        #expect(state.window?.newer != nil)
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["Older page"])
        #expect(state.turns["turn"]?.items["latest"] != nil)
    }

    @Test func aFarBackWindowShowsNoOutcomeForALiveTurnOutsideIt() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try lifecycle("turn/started", turnID: "empty", status: "inProgress"))
        state.apply(try lifecycle("turn/completed", turnID: "empty", status: "completed"))
        func outcomes(_ state: ConversationState) -> [String] {
            ConversationProjection.project(state).items.compactMap { if case .turnOutcome(let outcome) = $0 { outcome.turnID } else { nil } }
        }
        #expect(outcomes(state) == ["empty"])
        state.merge(farBack([.init(turnId: "turn", item: .agentMessage(id: "old", text: "Older page"), startedAtOrdinal: 0, isComplete: true)]))
        #expect(state.window?.newer != nil)
        #expect(state.turns["empty"] != nil)
        #expect(outcomes(state).isEmpty)
    }

    @Test func theStoredTailReplacesAFarBackWindowButNotOneThatReachesTheLatestHistory() throws {
        let stored = GatewayHistoryService.ConversationSnapshot.fixture(
            wire: entries([.agentMessage(id: "stored", text: "Stored tail")], turnID: "stored-turn"), source: .storedTail)
        var farBackState = ConversationState(conversationID: UUID(), threadID: "thread")
        farBackState.merge(farBack([.init(turnId: "turn", item: .agentMessage(id: "old", text: "Older page"), startedAtOrdinal: 0, isComplete: true)]))
        #expect(farBackState.window?.newer != nil)
        farBackState.merge(stored)
        #expect(farBackState.window?.newer == nil)
        #expect(ConversationProjection.project(farBackState).messages.map(\.text) == ["Stored tail"])

        var latest = ConversationState(conversationID: UUID(), threadID: "thread")
        latest.merge(history(items: [.agentMessage(id: "a1", text: "Newest")]))
        latest.merge(stored)
        #expect(ConversationProjection.project(latest).messages.map(\.text) == ["Newest"])
    }

    @Test func aTrimmedLiveTurnKeepsItsReloadEdgeWhenAnOlderPageMerges() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: entries([.agentMessage(id: "first", text: "First")], turnID: "turn"), turns: [summary("turn")],
            older: "before-first"))
        for index in 1...450 {
            state.apply(try event("item/completed", item: .agentMessage(id: "m-\(index)", text: "Message \(index)"), ordinal: index))
        }
        let reload = HistoryEdge(kind: .reload(turnID: "turn"), cursor: nil).id
        #expect(ConversationProjection.project(state).items.contains { $0.id == reload })
        state.merge(.fixture(wire: entries([.agentMessage(id: "older", text: "Older")], turnID: "older-turn"),
            placement: .older("before-first"), base: state.window))
        #expect(state.window?.turn("older-turn") != nil)
        #expect(ConversationProjection.project(state).items.contains { $0.id == reload })
    }

    @Test func completedCheckpointDominatesQueuedStartAndDeltaWhileInterruptedTurnsCanResume() throws {
        let header = history(items: []).header
        let checkpoint = CodexAppServerV2.ThreadObservationCheckpoint(turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil, activeTurn: nil, historyUnavailable: false, liveItems: [
                .init(turnId: "turn", item: .agentMessage(id: "answer", text: "before "), isComplete: false)
            ])
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let completed = CodexAppServerV2.Turn(id: "turn", items: [],
            startedAt: 1, completedAt: 2, status: .completed, error: nil)
        state.mergeObservation(header: header, checkpoint: checkpoint, history: .init(turns: [completed], entries: [
            .init(turnId: "turn", item: .agentMessage(id: "answer", text: "before after"), startedAtOrdinal: 5, isComplete: true)
        ], update: nil))
        let started = try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object([
            "id": .string("turn"), "items": .array([]), "status": .string("inProgress")
        ])]), method: "turn/started")
        state.apply(started)
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turnId": .string("turn"),
            "itemId": .string("answer"), "delta": .string("after")]), method: "item/agentMessage/delta"))
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["before after"])
        #expect(state.turns["turn"]?.isActive == false)
        state.turns["turn"]?.terminalStatus = .interrupted
        state.apply(started)
        #expect(state.turns["turn"]?.isActive == true)
    }

    @Test func aQuestionAboveTheWindowTakesItsPagedOrdinal() throws {
        let user = CodexAppServerV2.ThreadItem.userMessage(id: "u", content: [.text(text: "Start", textElements: [])])
        let question = CodexAppServerV2.ThreadItem.agentMessage(id: "call_q", text: "Which one?\n- A\n- B",
            phase: .finalAnswer, delivery: .async, questions: [.init(title: "Which one?", options: ["A", "B"])])
        let tail: [CodexAppServerV2.ThreadItemsListResponse.Entry] = [
            .init(turnId: "turn", item: .agentMessage(id: "later", text: "Continuing"), startedAtOrdinal: 3, isComplete: true),
            .init(turnId: "turn", item: tool("t1", status: .completed), startedAtOrdinal: 2, isComplete: true),
        ]
        func visibleIDs(_ state: ConversationState) -> [String] {
            state.turns["turn"].map { state.visibleItems(in: $0) } ?? []
        }

        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: tail, turns: [summary("turn")], older: "older-items"))
        #expect(visibleIDs(state) == ["t1", "later"])
        #expect(state.turns["turn"]?.items["call_q"] == nil)
        let unloaded = ConversationProjection.project(state)
        #expect(unloaded.pendingQuestion == nil)
        #expect(unloaded.questionCoverage == .unavailable)
        #expect(!unloaded.items.contains { if case .question = $0 { true } else { false } })

        state.merge(.fixture(wire: [
            .init(turnId: "turn", item: question, startedAtOrdinal: 1, isComplete: true),
            .init(turnId: "turn", item: user, startedAtOrdinal: 0, isComplete: true),
        ], placement: .older("older-items"), base: state.window))
        #expect(visibleIDs(state) == ["u", "call_q", "t1", "later"])
        #expect(state.turns["turn"]?.items["call_q"]?.position == 1)

        state.merge(.fixture(wire: tail, turns: [summary("turn")], older: "older-items", placement: .reset))
        #expect(visibleIDs(state) == ["t1", "later"])
    }

    @Test func questionCardsKeepHistoryAndReplyDisplayWithoutInferringAttention() throws {
        let question = CodexAppServerV2.ThreadItem.agentMessage(id: "call_q", text: "Which one?",
            phase: .finalAnswer, delivery: .async, questions: [.init(title: "Which one?", options: ["A", "B"])])
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [.userMessage(id: "u", content: [.text(text: "Start", textElements: [])]), question]))
        let replies = [QuestionReply(question: "Which one?", answer: "A")]
        let local = ChatMessage(role: .user, text: QuestionReply.displayText(replies), questionReplies: replies)
        state.submit(local, input: QuestionReplyEnvelope.text(itemID: "call_q", replies: replies))
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.pendingQuestion == nil)
        #expect(snapshot.messages.last?.text == "A")
        #expect(snapshot.messages.last?.questionReplies == replies)
        let card = try #require(snapshot.questionPrompts["call_q"])
        #expect(card.record == nil)
        #expect(!card.isCurrent)
        #expect(snapshot.items.contains { $0.id == ChatStreamItem.questionRowID(itemID: "call_q") })
    }

    @Test func forkMenuRequiresFinalReplyAndCompletedTurn() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let items: [CodexAppServerV2.ThreadItem] = [
            .userMessage(id: "user", content: [.text(text: "Start", textElements: [])], clientId: nil),
            .agentMessage(id: "commentary", text: "Working"),
            .userMessage(id: "steer", content: [.text(text: "Also this", textElements: [])], clientId: nil),
            .agentMessage(id: "final", text: "Done")
        ]
        state.merge(history(items: items))
        #expect(ConversationProjection.project(state).forkableMessageIDs.isEmpty)

        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"),
            "turn": .object(["id": .string("turn"), "status": .string("completed")])]), method: "turn/completed"))
        let finished = ConversationProjection.project(state)
        let final = try #require(finished.messages.last)
        #expect(finished.forkableMessageIDs == [final.id])

        state.activity(turnID: "turn", active: true)
        #expect(ConversationProjection.project(state).forkableMessageIDs.isEmpty)
    }

    @Test func forkMenuRejectsMissingTailAndActivityAfterReply() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(farBack([.init(turnId: "turn", item: .agentMessage(id: "reply", text: "An intermediate reply"), isComplete: true)]))
        state.turns["turn"]?.terminalStatus = .completed
        state.turns["turn"]?.terminal = true
        #expect(ConversationProjection.project(state).forkableMessageIDs.isEmpty)

        state.window = nil
        state.apply(try event("item/completed", item: tool("later-tool", status: .completed), ordinal: 2))
        #expect(ConversationProjection.project(state).forkableMessageIDs.isEmpty)
    }

    @Test func aRememberedTokenUsageShowsWhileItsTurnIsTheFinishedNewest() throws {
        let usage = try tokenUsage(totalTokens: 12_345)
        let finished = history(items: [.agentMessage(id: "a1", text: "Done")], turnID: "t1", status: .completed)
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(finished)
        #expect(state.validTokenUsage == nil)
        state.recordTokenUsage(turnID: "t1", usage: usage)
        #expect(state.validTokenUsage?.last.totalTokens == 12_345)

        var reopened = ConversationState(conversationID: state.conversationID, threadID: "thread")
        reopened.restore(try JSONDecoder().decode(ConversationState.Checkpoint.self, from: JSONEncoder().encode(state.checkpoint)))
        #expect(reopened.validTokenUsage == nil)
        reopened.merge(finished)
        #expect(reopened.validTokenUsage?.last.totalTokens == 12_345)
    }

    @Test func aCachedTailReplacingAGatewayTailMakesTheRememberedTokenUsageUnknown() throws {
        let finished = entries([.agentMessage(id: "a1", text: "Done")], turnID: "t1")
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: finished, turns: [summary("t1", status: .completed)]))
        state.recordTokenUsage(turnID: "t1", usage: try tokenUsage(totalTokens: 12_345))
        #expect(state.validTokenUsage?.last.totalTokens == 12_345)
        state.merge(.fixture(wire: finished, turns: [summary("t1", status: .completed)], source: .cachedPages))
        #expect(state.validTokenUsage == nil)
    }

    @Test func aNewerRunningOrUnverifiedTurnMakesTheRememberedTokenUsageUnknown() throws {
        let usage = try tokenUsage(totalTokens: 12_345)
        let t1 = entries([.agentMessage(id: "a1", text: "Done")], turnID: "t1")
        let t2 = entries([.agentMessage(id: "a2", text: "From another device")], turnID: "t2")

        var newer = ConversationState(conversationID: UUID(), threadID: "thread")
        newer.merge(.fixture(wire: t1, turns: [summary("t1", status: .completed)]))
        newer.recordTokenUsage(turnID: "t1", usage: usage)
        newer.merge(.fixture(wire: t2 + t1, turns: [summary("t2", status: .completed), summary("t1", status: .completed)]))
        #expect(newer.validTokenUsage == nil)

        var running = ConversationState(conversationID: UUID(), threadID: "thread")
        running.merge(.fixture(wire: t1, turns: [summary("t1")]))
        running.recordTokenUsage(turnID: "t1", usage: usage)
        #expect(running.validTokenUsage == nil)

        var cached = ConversationState(conversationID: UUID(), threadID: "thread")
        cached.merge(.fixture(wire: t1, turns: [summary("t1", status: .completed)], source: .cachedPages))
        cached.recordTokenUsage(turnID: "t1", usage: usage)
        #expect(cached.validTokenUsage == nil)

        var live = ConversationState(conversationID: UUID(), threadID: "thread")
        live.merge(.fixture(wire: t1, turns: [summary("t1", status: .completed)]))
        live.recordTokenUsage(turnID: "t1", usage: usage)
        live.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("t2"), "status": .string("inProgress")])]),
            method: "turn/started"))
        #expect(live.validTokenUsage == nil)
    }

    private func finishedTurn(at completedAt: Int64) -> CodexAppServerV2.Turn {
        CodexAppServerV2.Turn(id: "finished", items: [], startedAt: 1,
                              completedAt: completedAt, status: .completed, error: nil)
    }

    private func claudeHistory(items: [CodexAppServerV2.ThreadItem], turnID: String) -> GatewayHistoryService.ConversationSnapshot {
        claudeHistory(turns: [(turnID, items)])
    }

    private func claudeHistory(turns: [(id: String, items: [CodexAppServerV2.ThreadItem])]) -> GatewayHistoryService.ConversationSnapshot {
        .fixture(threadID: "claude_thread", wire: turns.reversed().flatMap { entries($0.items, turnID: $0.id, ordered: false) },
                 turns: turns.reversed().map { summary($0.id) })
    }

    private func headed(_ snapshot: GatewayHistoryService.ConversationSnapshot,
                        lastTurnCompletedAt: Int64) -> GatewayHistoryService.ConversationSnapshot {
        var header = snapshot.header
        header.lastTurnCompletedAt = lastTurnCompletedAt
        return .init(header: header, window: snapshot.window, update: snapshot.update, fetchedAt: snapshot.fetchedAt, source: snapshot.source)
    }

    private func farBack(_ wire: [CodexAppServerV2.ThreadItemsListResponse.Entry]) -> GatewayHistoryService.ConversationSnapshot {
        let tail = measured([.init(turnId: "newest", item: .agentMessage(id: "newest", text: "Newest"), isComplete: true)],
            older: "before-newest", placement: .tail, base: nil)
        return measured(wire, older: nil, placement: .older("before-newest"), base: tail.window)
    }

    private func tokenUsage(totalTokens: Int64) throws -> CodexAppServerV2.ThreadTokenUsage {
        let breakdown: [String: Any] = [
            "totalTokens": totalTokens, "inputTokens": totalTokens, "cachedInputTokens": 0,
            "outputTokens": 0, "reasoningOutputTokens": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: ["total": breakdown, "last": breakdown, "modelContextWindow": 400_000])
        return try JSONDecoder().decode(CodexAppServerV2.ThreadTokenUsage.self, from: data)
    }

    private func tool(_ id: String, status: CodexAppServerV2.CommandExecutionStatus) -> CodexAppServerV2.ThreadItem {
        .commandExecution(id: id, command: "sleep 1", cwd: "/tmp", status: status,
                          commandActions: [], aggregatedOutput: nil, exitCode: status == .completed ? 0 : nil, durationMs: nil)
    }
}

extension ConversationStateTests {
    @Test func expansionAndRepeatedActivityDoNotDirtyDurableContent() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/completed", item: tool("cmd", status: .completed), ordinal: 1))
        let group = try #require(ConversationProjection.project(state).timelines.first)
        let before = state.persistenceRevision
        state.toggleTimeline(group.id)
        #expect(state.persistenceRevision == before)
        #expect(ConversationProjection.project(state).timelines.first?.isExpanded != group.isExpanded)
        state.activity(turnID: "turn", active: false)
        #expect(state.persistenceRevision == before)
        state.activity(turnID: "turn", active: true)
        #expect(state.persistenceRevision == before + 1)
        state.activity(turnID: "turn", active: true)
        #expect(state.persistenceRevision == before + 1)
        let changed = state.persistenceRevision
        state.apply(try event("item/completed", item: tool("cmd", status: .completed), ordinal: 1), replay: true)
        #expect(state.persistenceRevision == changed)
    }
}

extension ConversationStateTests {
    @Test func streamedDeltasStayOutOfTheDurableRevisionUntilCommitted() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1))
        let durable = state.persistenceRevision
        let revision = state.revision
        for text in ["Hello", " world"] { state.apply(try agentDelta(text)) }
        #expect(state.revision == revision + 2)
        #expect(state.persistenceRevision == durable)
        state.commitLiveChanges()
        #expect(state.persistenceRevision == durable + 1)
        state.commitLiveChanges()
        #expect(state.persistenceRevision == durable + 1)
        state.apply(try agentDelta("!"))
        state.apply(try event("item/completed", item: .agentMessage(id: "answer", text: "Hello world!"), ordinal: 1))
        state.commitLiveChanges()
        #expect(state.persistenceRevision == durable + 2)
    }
}

extension ConversationStateTests {
    @Test func memoizedProjectionMatchesAFreshProjectionThroughoutALiveConversation() throws {
        let user = { (id: String) in CodexAppServerV2.ThreadItem.userMessage(id: id, content: [.text(text: "Prompt \(id)", textElements: [])]) }
        let reply = { (id: String) in CodexAppServerV2.ThreadItem.agentMessage(id: id, text: "Reply \(id)") }
        var memo = ConversationProjection.Memo()
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        try expectMemoMatchesFreshProjection(state, memo: &memo, "empty")

        var prior = ConversationState(conversationID: state.conversationID, threadID: "thread")
        prior.apply(try lifecycle("turn/started", turnID: "t1", status: "inProgress"))
        prior.apply(try itemEvent("item/completed", user("t1-u"), turnID: "t1", ordinal: 0))
        prior.apply(try itemEvent("item/completed", tool("t1-cmd", status: .completed), turnID: "t1", ordinal: 1))
        prior.apply(try itemEvent("item/completed", reply("t1-a"), turnID: "t1", ordinal: 2))
        prior.apply(try lifecycle("turn/completed", turnID: "t1", status: "completed"))
        state.restore(prior.checkpoint)
        try expectMemoMatchesFreshProjection(state, memo: &memo, "restore")

        state.merge(.fixture(wire: [
            .init(turnId: "t2", item: reply("t2-a"), startedAtOrdinal: 4, startedAtMs: 4000, completedAtMs: 4100, isComplete: true),
            .init(turnId: "t2", item: tool("t2-cmd", status: .completed), startedAtOrdinal: 3, startedAtMs: 3000, completedAtMs: 3100, isComplete: true),
        ], turns: [summary("t2", status: .completed), summary("t1", status: .completed)], older: "t2-older"))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "history window")

        let message = ChatMessage(role: .user, text: "Live prompt")
        state.submit(message)
        try expectMemoMatchesFreshProjection(state, memo: &memo, "submit")
        state.accepted(message.id, turnID: "live")
        try expectMemoMatchesFreshProjection(state, memo: &memo, "accepted")
        state.apply(try lifecycle("turn/started", turnID: "live", status: "inProgress"))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "turn started")
        state.apply(try itemEvent("item/completed", .userMessage(id: "live-u", content: [.text(text: message.text, textElements: [])],
            clientId: message.id.uuidString), turnID: "live", ordinal: 10))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "canonical user")
        state.apply(try itemEvent("item/started", tool("live-cmd", status: .inProgress), turnID: "live", ordinal: 11))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "tool started")
        state.apply(try itemEvent("item/started", .agentMessage(id: "live-a", text: ""), turnID: "live", ordinal: 12))
        for text in ["Stream", "ing ", "reply"] {
            state.apply(try liveDelta(text, itemID: "live-a", turnID: "live"))
            try expectMemoMatchesFreshProjection(state, memo: &memo, "delta \(text)")
        }
        state.apply(try itemEvent("item/completed", tool("live-cmd", status: .completed), turnID: "live", ordinal: 11))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "tool completed")
        state.apply(try itemEvent("item/completed", reply("t1-late"), turnID: "t1", ordinal: 3))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "older turn item")

        let question = CodexAppServerV2.ThreadItem.agentMessage(id: "call_q", text: "Which one?", phase: .finalAnswer,
            delivery: .async, questions: [.init(title: "Which one?", options: ["A", "B"])])
        state.apply(try itemEvent("item/completed", question, turnID: "live", ordinal: 13))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "question item")
        var inventory = QuestionInventory()
        try inventory.merge(.init(threadId: "thread", epoch: "epoch", revision: 1, coverage: .ready, reason: nil,
            records: [.init(itemId: "call_q", turnId: "live", ordinal: 13, askedAtMs: nil, revision: 1,
                questions: [.init(index: 0, title: "Which one?", options: ["A", "B"], resolution: .pending, answer: nil)])],
            pendingItemIds: ["call_q"], missingItemIds: []))
        state.questions = inventory
        try expectMemoMatchesFreshProjection(state, memo: &memo, "pending question")
        #expect(ConversationProjection.project(state, memo: &memo).items.contains {
            if case .question(let prompt) = $0 { prompt.isPending } else { false }
        })
        try inventory.merge(.init(threadId: "thread", epoch: "epoch", revision: 2, coverage: .ready, reason: nil,
            records: [.init(itemId: "call_q", turnId: "live", ordinal: 13, askedAtMs: nil, revision: 2,
                questions: [.init(index: 0, title: "Which one?", options: ["A", "B"], resolution: .answered,
                    answer: .init(text: "A", itemId: "answer", clientId: nil, ordinal: 14, atMs: nil))])],
            pendingItemIds: [], missingItemIds: []))
        state.questions = inventory
        try expectMemoMatchesFreshProjection(state, memo: &memo, "answered question")

        state.apply(try itemEvent("item/completed", reply("live-a"), turnID: "live", ordinal: 12))
        state.apply(try lifecycle("turn/completed", turnID: "live", status: "completed"))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "turn completed")

        state.merge(.fixture(wire: [
            .init(turnId: "t2", item: reply("t2-mid"), startedAtOrdinal: 2, startedAtMs: 2000, completedAtMs: 2100, isComplete: true),
            .init(turnId: "t2", item: user("t2-u"), startedAtOrdinal: 1, startedAtMs: 1000, completedAtMs: 1100, isComplete: true),
            .init(turnId: "t1", item: reply("t1-a"), startedAtOrdinal: 2, startedAtMs: 1000, completedAtMs: 2002, isComplete: true),
            .init(turnId: "t1", item: user("t1-u"), startedAtOrdinal: 0, startedAtMs: 1000, completedAtMs: 2000, isComplete: true),
        ], placement: .older("t2-older"), base: state.window))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "older page")

        let group = try #require(ConversationProjection.project(state).timelines.first)
        state.toggleTimeline(group.id)
        try expectMemoMatchesFreshProjection(state, memo: &memo, "toggle")
        state.activity(turnID: "t2", active: true)
        try expectMemoMatchesFreshProjection(state, memo: &memo, "activity")
        state.activity(turnID: "t2", active: false)

        for index in 0..<36 {
            let id = "r\(index)"
            state.apply(try lifecycle("turn/started", turnID: id, status: "inProgress"))
            state.apply(try itemEvent("item/completed", user("\(id)-u"), turnID: id, ordinal: 0))
            state.apply(try itemEvent("item/completed", reply("\(id)-a"), turnID: id, ordinal: 1))
            state.apply(try lifecycle("turn/completed", turnID: id, status: "completed"))
            try expectMemoMatchesFreshProjection(state, memo: &memo, "turn \(id)")
        }
        #expect(state.turns["live"] == nil)
        #expect(state.turns["t1"] != nil)
    }

    @Test func anOlderCompletedProjectionCannotReplaceTheCurrentMemo() async throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try lifecycle("turn/started", turnID: "live", status: "inProgress"))
        state.apply(try itemEvent("item/started", .agentMessage(id: "answer", text: "Before"), turnID: "live", ordinal: 0))
        let old = await ConversationProjection.render(state, memo: .init(), signposter: ConversationProjection.signposter)
        state.apply(try liveDelta(" after", itemID: "answer", turnID: "live"))
        let current = await ConversationProjection.render(state, memo: old.memo, signposter: ConversationProjection.signposter)
        var accepted = ConversationProjection.Memo()
        accepted.replace(with: current.memo, currentRevision: state.revision)
        accepted.replace(with: old.memo, currentRevision: state.revision)
        let snapshot = ConversationProjection.project(state, memo: &accepted)
        #expect(snapshot.messages.map(\.text) == ["Before after"])
        #expect(accepted.projectedTurnCount == 0)
    }

    @Test func aStreamedDeltaReprojectsOnlyTheLiveTurn() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [.agentMessage(id: "loaded", text: "Loaded page")], turnID: "loaded"))
        for index in 0..<6 {
            let id = "done-\(index)"
            state.apply(try lifecycle("turn/started", turnID: id, status: "inProgress"))
            state.apply(try itemEvent("item/completed", tool("\(id)-cmd", status: .completed), turnID: id, ordinal: 0))
            state.apply(try itemEvent("item/completed", .agentMessage(id: "\(id)-a", text: "Done \(index)"), turnID: id, ordinal: 1))
            state.apply(try lifecycle("turn/completed", turnID: id, status: "completed"))
        }
        state.apply(try lifecycle("turn/started", turnID: "live", status: "inProgress"))
        state.apply(try itemEvent("item/started", .agentMessage(id: "answer", text: ""), turnID: "live", ordinal: 0))
        var memo = ConversationProjection.Memo()
        _ = ConversationProjection.project(state, memo: &memo)
        #expect(memo.projectedTurnCount == state.order.count)
        for text in ["Hel", "lo"] {
            state.apply(try liveDelta(text, itemID: "answer", turnID: "live"))
            let snapshot = ConversationProjection.project(state, memo: &memo)
            #expect(memo.projectedTurnCount == 1)
            #expect(snapshot.items == ConversationProjection.project(state).items)
        }
        #expect(ConversationProjection.project(state, memo: &memo).messages.last?.text == "Hello")
        #expect(memo.projectedTurnCount == 0)
    }

    @Test func aStreamedDeltaDoesNotPayForTheLoadedHistoryWindow() throws {
        func streamingState(historyTurns: Int, itemsPerTurn: Int) throws -> ConversationState {
            let turns = (0..<historyTurns).map { summary("history-\($0)", status: .completed) }
            let wire = turns.reversed().flatMap { turn in
                (0..<itemsPerTurn).reversed().map { index in
                    CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: turn.id,
                        item: .agentMessage(id: "\(turn.id)-\(index)", text: "Loaded \(index)"),
                        startedAtOrdinal: Int64(index), completedAtMs: 2000, isComplete: true)
                }
            }
            var state = ConversationState(conversationID: UUID(), threadID: "thread")
            state.merge(.fixture(wire: wire, turns: turns.reversed()))
            state.apply(try lifecycle("turn/started", turnID: "live", status: "inProgress"))
            state.apply(try itemEvent("item/started", .agentMessage(id: "answer", text: ""), turnID: "live", ordinal: 0))
            return state
        }
        let delta = try liveDelta("token ", itemID: "answer", turnID: "live")
        func streamingCost(_ initial: ConversationState) -> Duration {
            var state = initial
            return ContinuousClock().measure { for _ in 0..<100 { state.apply(delta) } }
        }
        let small = try streamingState(historyTurns: 1, itemsPerTurn: 1)
        let large = try streamingState(historyTurns: 30, itemsPerTurn: 100)
        #expect(large.order.count == 31)
        let costs = (0..<3).map { _ in (small: streamingCost(small), large: streamingCost(large)) }
        let smallCost = costs.map { $0.small }.min() ?? .zero
        let largeCost = costs.map { $0.large }.min() ?? .zero
        #expect(largeCost < smallCost * 4 + .milliseconds(20), "small \(smallCost), large \(largeCost)")
    }

    @Test func aRepeatedHistoryReadReprojectsOnlyTheTurnItChanged() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "claude_thread")
        let turns: [(id: String, items: [CodexAppServerV2.ThreadItem])] = (0..<3).map { index in
            ("turn-\(index)", [.agentMessage(id: "reply-\(index)", text: "Reply \(index)")])
        }
        state.merge(claudeHistory(turns: turns))
        var memo = ConversationProjection.Memo()
        _ = ConversationProjection.project(state, memo: &memo)
        #expect(memo.projectedTurnCount == 3)

        state.merge(claudeHistory(turns: turns))
        _ = ConversationProjection.project(state, memo: &memo)
        #expect(memo.projectedTurnCount == 0)

        var grown = turns
        grown[1].items.append(.agentMessage(id: "reply-1b", text: "More"))
        state.merge(claudeHistory(turns: grown))
        try expectMemoMatchesFreshProjection(state, memo: &memo, "after one turn grew")
        #expect(memo.projectedTurnCount == 1)
    }

    private func expectMemoMatchesFreshProjection(_ state: ConversationState, memo: inout ConversationProjection.Memo,
                                                  _ step: Comment, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let cached = ConversationProjection.project(state, memo: &memo)
        let fresh = ConversationProjection.project(state)
        #expect(cached.items == fresh.items, step, sourceLocation: sourceLocation)
        #expect(cached.messages == fresh.messages, step, sourceLocation: sourceLocation)
        #expect(cached.timelines == fresh.timelines, step, sourceLocation: sourceLocation)
        #expect(cached.forkableMessageIDs == fresh.forkableMessageIDs, step, sourceLocation: sourceLocation)
        #expect(cached.questionPrompts == fresh.questionPrompts, step, sourceLocation: sourceLocation)
        #expect(cached.pendingQuestion == fresh.pendingQuestion, step, sourceLocation: sourceLocation)
        #expect(cached.questionCoverage == fresh.questionCoverage, step, sourceLocation: sourceLocation)
    }

    private func lifecycle(_ method: String, turnID: String, status: String) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string(turnID), "status": .string(status)])]),
            method: method)
    }

    private func itemEvent(_ method: String, _ item: CodexAppServerV2.ThreadItem, turnID: String, ordinal: Int) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.item(method, item: item, threadID: "thread", turnID: turnID, ordinal: ordinal,
            startedAtMs: 1000 + ordinal, completedAtMs: 2000 + ordinal)
    }

    private func liveDelta(_ text: String, itemID: String, turnID: String) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.delta(text, threadID: "thread", turnID: turnID, itemID: itemID)
    }
}
