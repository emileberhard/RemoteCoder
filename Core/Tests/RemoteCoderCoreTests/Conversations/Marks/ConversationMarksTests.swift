import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationMarksTests {
    @Test func unknownHostRetainsTheFinalPinOfASettledSource() throws {
        var host = ConversationMarksReplica()
        let source = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 100,
            threads: ["saved": ThreadMarks(markedUnread: true, pinName: "Pinned after settling", settlement: .settled(through: 200))]))
        try host.adopt(source, sourceID: UUID())
        #expect(host.effective.pinNames["saved"] == "Pinned after settling")
        #expect(host.effective.threads["saved"]?.settlement == .settled(through: 200))
        #expect(!host.isReadStateKnown)
        #expect(host.pending.isEmpty)
        var remote = try #require(source.acknowledged)
        remote.supportsRetiredScopeRead = true
        host.replaceAcknowledged(remote)
        #expect(host.effective.threads["saved"]?.markedUnread == true)
    }

    @Test func doneSuggestionsFollowLatestActivityAndExcludePinsAndPurposes() throws {
        let current = try thread("t", completedAt: 900)
        let marks = ConversationMarks(schemaVersion: 3, revision: 1, readBaseline: .max,
                                      threads: ["t": ThreadMarks(doneThrough: 900)])
        #expect(marks.marks(for: "t") != nil)
        #expect(marks.isProbablyDone(current))
        var prompted = current
        prompted.recencyAt = 901
        #expect(!marks.isProbablyDone(prompted))
        #expect(!marks.isProbablyDone(try thread("t", completedAt: 901)))
        #expect(!marks.isProbablyDone(try thread("other", completedAt: 900)))
        #expect(!marks.applying(.pin(threadID: "t", name: "Keep")).isProbablyDone(current))
        #expect(!marks.applying(.setPurpose(threadID: "t", purpose: .automation)).isProbablyDone(current))
        #expect(!marks.applying(.setPurpose(threadID: "t", purpose: .probe)).isProbablyDone(current))
    }

    @Test func unsettleClearsTheSuggestionOptimisticallyAndAfterAcknowledgement() throws {
        let current = try thread("t", completedAt: 900)
        let snapshot = ConversationMarks(schemaVersion: 3, revision: 1, readBaseline: .max,
                                         threads: ["t": ThreadMarks(doneThrough: 900)])
        var replica = ConversationMarksReplica(acknowledged: snapshot)
        replica.record(.unsettle(threadID: "t", through: 900))
        #expect(!replica.effective.isProbablyDone(current))
        #expect(replica.effective.threads["t"]?.doneThrough == nil)
        #expect(replica.effective.settlement(of: "t") == .active(through: 900))

        let optimistic = replica.effective
        replica.acknowledge(replica.pending, delta: ConversationMarks(schemaVersion: 3, revision: 2, readBaseline: .max,
            threads: ["t": ThreadMarks(revision: 2, settlement: .active(through: 900))]))
        #expect(!replica.effective.isProbablyDone(current))
        #expect(replica.effective.settlement(of: "t") == optimistic.settlement(of: "t"))
        #expect(replica.pending.isEmpty)
    }

    @Test func optionalDoneThroughRoundTripsWithoutChangingLegacyReplicaDecoding() throws {
        let old = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(#"{"acknowledged":{"schemaVersion":2,"revision":1,"readBaseline":5,"threads":{"t":{"revision":1}}},"pending":[]}"#.utf8))
        #expect(old.effective.threads["t"]?.doneThrough == nil)
        let current = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(#"{"acknowledged":{"schemaVersion":3,"revision":2,"readBaseline":5,"threads":{"t":{"revision":2,"doneThrough":900}}},"pending":[]}"#.utf8))
        let reloaded = try JSONDecoder().decode(ConversationMarksReplica.self, from: JSONEncoder().encode(current))
        #expect(reloaded == current)
        #expect(reloaded.effective.threads["t"]?.doneThrough == 900)
        #expect(reloaded.effective.offersSettlement)
    }

    @Test func restoringStoredCommandsPreservesGlobalMarksOrderIdentityAndLimit() {
        let storedMark = ConversationMarksReplica.Pending(id: UUID(), change: .markAllRead(through: 300))
        let admitted = ConversationMarksReplica.Pending(id: UUID(), change: .pin(threadID: "t", name: "New"))
        let stored = ConversationMarksReplica(acknowledged:
            ConversationMarks(schemaVersion: 2, revision: 4, readBaseline: 100, threads: [:]),
            pending: [storedMark, admitted])
        var replica = ConversationMarksReplica(pending: [admitted])
        replica.record(.unpin(threadID: "t"))
        let newest = replica.pending.last
        replica.restore(stored)
        #expect(replica.pending == [storedMark, admitted] + [newest].compactMap { $0 })
        #expect(replica.effective.readBaseline == 300)
        #expect(replica.effective.pinName(for: "t") == nil)
        for index in 0..<ConversationMarksReplica.pendingLimit { replica.record(.pin(threadID: "t", name: "\(index)")) }
        replica.restore(stored)
        #expect(replica.pending.count == ConversationMarksReplica.pendingLimit)
        #expect(replica.effective.pinName(for: "t") == "\(ConversationMarksReplica.pendingLimit - 1)")
    }

    @Test func onlyCompletionsAfterTheBaselineAndTheLastSeenOneAreUnread() throws {
        var marks = ConversationMarks(schemaVersion: 1, revision: 1, readBaseline: 100, threads: [:])
        #expect(marks.isUnread(try thread("a", completedAt: nil)) == false)
        #expect(marks.isUnread(try thread("a", completedAt: 100)) == false)

        let first = try thread("a", completedAt: 200)
        #expect(marks.isUnread(first))
        marks = marks.applying(.markRead(threadID: "a", through: 150))
        #expect(marks.isUnread(first))
        marks = marks.applying(.markRead(threadID: "a", through: 200))
        marks = marks.applying(.markRead(threadID: "a", through: 150))
        #expect(marks.marks(for: "a")?.seenThrough == 200)
        #expect(marks.isUnread(first) == false)
        #expect(marks.isUnread(try thread("a", completedAt: 300)))
        #expect(marks.isUnread(try thread("b", completedAt: 200)))
    }

    @Test func aQuestionNeedsYouOnlyWhenAskedAfterTheThreadWasLastRead() {
        var marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 100, threads: [:])
        #expect(marks.isUnseenQuestion(askedAtMs: 100_999, in: "a") == false)
        #expect(marks.isUnseenQuestion(askedAtMs: 101_000, in: "a"))
        marks = marks.applying(.markRead(threadID: "a", through: 200))
        #expect(marks.isUnseenQuestion(askedAtMs: 200_900, in: "a") == false)
        #expect(marks.isUnseenQuestion(askedAtMs: 201_000, in: "a"))
        #expect(marks.isUnseenQuestion(askedAtMs: 150_000, in: "b"))
        marks = marks.applying(.settle(threadID: "b", through: 300))
        #expect(marks.isUnseenQuestion(askedAtMs: 250_000, in: "b") == false)
    }

    @Test func manualUnreadWinsUntilReadAndPurposesNeverCountCompletions() throws {
        let finished = try thread("a", completedAt: 50)
        var marks = ConversationMarks(schemaVersion: 1, revision: 1, readBaseline: 100, threads: [:])
        marks = marks.applying(.markUnread(threadID: "a"))
        #expect(marks.isUnread(finished))
        marks = marks.applying(.markRead(threadID: "a", through: 0))
        #expect(marks.isUnread(finished) == false)
        #expect(marks.marks(for: "a") == nil)

        marks = marks.applying(.setPurpose(threadID: "b", purpose: .automation))
        #expect(marks.isUnread(try thread("b", completedAt: 500)) == false)
    }

    @Test func markAllReadMovesTheBaselineAndClearsWhatItCovers() throws {
        var marks = ConversationMarks(schemaVersion: 1, revision: 1, readBaseline: 100, threads: [
            "seen": ThreadMarks(revision: 1, seenThrough: 150),
            "flagged": ThreadMarks(revision: 1, markedUnread: true),
            "pinned": ThreadMarks(revision: 1, seenThrough: 900, pinName: "Keep"),
        ])
        marks = marks.applying(.markAllRead(through: 500))
        #expect(marks.readBaseline == 500)
        #expect(marks.marks(for: "seen") == nil)
        #expect(marks.marks(for: "flagged") == nil)
        #expect(marks.marks(for: "pinned")?.seenThrough == 900)
        #expect(marks.isUnread(try thread("x", completedAt: 400)) == false)
        #expect(marks.applying(.markAllRead(through: 300)).readBaseline == 500)
    }

    @Test func deltasApplyOnlyNewerEntriesAndEmptyOnesRemove() {
        var marks = ConversationMarks(schemaVersion: 1, revision: 4, readBaseline: 100, threads: [
            "a": ThreadMarks(revision: 4, pinName: "Current"),
            "b": ThreadMarks(revision: 2, pinName: "Old"),
        ])
        marks.apply(ConversationMarks(schemaVersion: 2, revision: 5, readBaseline: 50, threads: [
            "a": ThreadMarks(revision: 3, pinName: "Stale"),
            "b": ThreadMarks(revision: 5),
            "c": ThreadMarks(revision: 5, settlement: .settled(through: 9)),
        ]))
        #expect(marks.schemaVersion == 2)
        #expect(marks.revision == 5)
        #expect(marks.readBaseline == 100)
        #expect(marks.pinName(for: "a") == "Current")
        #expect(marks.marks(for: "b") == nil)
        #expect(marks.settlement(of: "c") == .settled(through: 9))

        marks.apply(ConversationMarks(schemaVersion: 1, revision: 4, readBaseline: 100, threads: [
            "b": ThreadMarks(revision: 4, pinName: "Late"),
        ]))
        #expect(marks.pinName(for: "b") == nil)
        #expect(marks.schemaVersion == 2)
    }

    @Test func pinNamesAreTrimmedAndClampedToTheGatewayLimitAtCharacterBoundaries() {
        #expect(ConversationPinName.normalized("  \n ") == nil)
        #expect(ConversationPinName.normalized(" Release ") == "Release")
        let long = String(repeating: "é", count: 200)
        let clamped = ConversationPinName.clamped(long)
        #expect(clamped.utf8.count == ConversationPinName.maximumBytes)
        #expect(clamped == String(repeating: "é", count: 128))
        let marks = ConversationMarks(schemaVersion: 1, revision: 1, readBaseline: 0, threads: [:])
            .applying(.pin(threadID: "a", name: long))
        #expect(marks.pinName(for: "a") == clamped)
    }

    @Test func changesUseTheGatewayWireShape() throws {
        let encoded = try JSONEncoder().encode([
            ConversationMarkChange.markRead(threadID: "t", through: 5),
            .markAllRead(through: 7),
            .pin(threadID: "t", name: "Keep"),
            .setPurpose(threadID: "t", purpose: .probe),
            .settle(threadID: "t", through: 11),
            .unsettle(threadID: "t", through: 12),
        ])
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(wire[0]["op"] as? String == "markRead")
        #expect(wire[0]["threadId"] as? String == "t")
        #expect(wire[0]["through"] as? Int == 5)
        #expect(wire[1].keys.sorted() == ["op", "through"])
        #expect(wire[1]["through"] as? Int == 7)
        #expect(wire[2]["name"] as? String == "Keep")
        #expect(wire[3]["purpose"] as? String == "probe")
        #expect(wire[4].keys.sorted() == ["op", "threadId", "through"])
        #expect(wire[4]["op"] as? String == "settle")
        #expect(wire[4]["through"] as? Int == 11)
        #expect(wire[5]["op"] as? String == "unsettle")
        #expect(wire[5]["through"] as? Int == 12)
        #expect(try JSONDecoder().decode([ConversationMarkChange].self, from: encoded).count == 6)
    }

    @Test func documentsCarryTheirSchemaVersionAndSettlementState() throws {
        let legacy = try JSONDecoder().decode(ConversationMarks.self, from: Data(#"{"revision":1,"readBaseline":5,"threads":{}}"#.utf8))
        #expect(legacy.schemaVersion == 1)
        #expect(!legacy.offersSettlement)

        let current = try JSONDecoder().decode(ConversationMarks.self, from: Data(#"""
            {"schemaVersion":2,"revision":3,"readBaseline":5,"threads":{
              "s":{"revision":3,"settlement":{"state":"settled","through":40}},
              "a":{"revision":2,"settlement":{"state":"active","through":50}}}}
            """#.utf8))
        #expect(current.offersSettlement)
        #expect(current.settlement(of: "s") == .settled(through: 40))
        #expect(current.settlement(of: "a") == .active(through: 50))

        let encoded = try JSONEncoder().encode(ConversationSettlement.settled(through: 40))
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(wire["state"] as? String == "settled")
        #expect(wire["through"] as? Int == 40)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ConversationSettlement.self, from: Data(#"{"state":"archived","through":1}"#.utf8))
        }
    }

    @Test func settleAndUnsettleApplyTheGatewaySemantics() {
        var marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 100, threads: [
            "a": ThreadMarks(revision: 1, seenThrough: 150, markedUnread: true, pinName: "Keep"),
            "b": ThreadMarks(revision: 1, seenThrough: 500, purpose: .automation),
        ])
        marks = marks.applying(.settle(threadID: "a", through: 300))
        #expect(marks.threads["a"] == ThreadMarks(revision: 1, seenThrough: 300, settlement: .settled(through: 300)))

        marks = marks.applying(.settle(threadID: "b", through: 200))
        #expect(marks.threads["b"] == ThreadMarks(revision: 1, seenThrough: 500, purpose: .automation,
                                                  settlement: .settled(through: 200)))

        marks = marks.applying(.settle(threadID: "c", through: 50))
        #expect(marks.threads["c"] == ThreadMarks(settlement: .settled(through: 50)))

        marks = marks.applying(.unsettle(threadID: "a", through: 400))
        #expect(marks.threads["a"] == ThreadMarks(revision: 1, seenThrough: 300, settlement: .active(through: 400)))

        for change: ConversationMarkChange in [.pin(threadID: "a", name: "Again"), .unpin(threadID: "a"),
                                               .markUnread(threadID: "a"), .markRead(threadID: "a", through: 900),
                                               .setPurpose(threadID: "a", purpose: .probe), .markAllRead(through: 950)] {
            marks = marks.applying(change)
            #expect(marks.settlement(of: "a") == .active(through: 400))
        }
    }

    @Test func settlementCoversRequestsMadeBeforeItsThroughOrTheAutomaticWindow() throws {
        let now: Int64 = 1_000_000
        let automatic = now - ConversationSettlement.automaticAfter
        func covers(_ requestAt: Int64?, _ settlement: ConversationSettlement? = nil,
                    schemaVersion: Int = 2) throws -> Bool {
            let marks = ConversationMarks(schemaVersion: schemaVersion, revision: 1, readBaseline: .max,
                                          threads: settlement.map { ["t": ThreadMarks(revision: 1, settlement: $0)] } ?? [:])
            return marks.coversRequest(madeAt: requestAt, in: try thread("t", completedAt: 500), at: now)
        }

        #expect(try covers(automatic))
        #expect(try !covers(automatic + 1))
        #expect(try covers(950_000, .settled(through: 950_000)))
        #expect(try !covers(950_001, .settled(through: 950_000)))
        #expect(try covers(automatic, .settled(through: 500)))
        #expect(try !covers(automatic, .active(through: 900_000)))
        #expect(try covers(automatic, .active(through: 400)))
        #expect(try !covers(0, schemaVersion: 1))
        #expect(try !covers(nil))
        #expect(try !covers(nil, .active(through: 400)))
        #expect(try covers(nil, .settled(through: 500)))
        #expect(try !covers(nil, .settled(through: 499)))
    }

    @Test func settlementFollowsTheDerivationTable() throws {
        let now: Int64 = 1_000_000
        let threshold = now - ConversationSettlement.automaticAfter
        func isSettled(_ activity: Int64, _ thread: ThreadMarks? = nil, readBaseline: Int64 = .max,
                       isLive: Bool = false, schemaVersion: Int = 2) throws -> Bool {
            let marks = ConversationMarks(schemaVersion: schemaVersion, revision: 1, readBaseline: readBaseline,
                                          threads: thread.map { ["t": $0] } ?? [:])
            return marks.isSettled(try self.thread("t", completedAt: activity), isLive: isLive, at: now)
        }

        #expect(ConversationSettlement.automaticAfter == 259_200)
        #expect(try isSettled(threshold))
        #expect(try !isSettled(threshold + 1))

        #expect(try isSettled(900_000, ThreadMarks(settlement: .settled(through: 900_000))))
        #expect(try !isSettled(900_001, ThreadMarks(settlement: .settled(through: 900_000))))
        #expect(try isSettled(threshold, ThreadMarks(settlement: .settled(through: 500))))

        #expect(try !isSettled(500, ThreadMarks(settlement: .active(through: 900_000))))
        #expect(try isSettled(600, ThreadMarks(settlement: .active(through: 500))))
        #expect(try !isSettled(threshold + 1, ThreadMarks(settlement: .active(through: 500))))

        #expect(try isSettled(now, ThreadMarks(purpose: .automation, settlement: .settled(through: 500))))
        #expect(try !isSettled(now, ThreadMarks(purpose: .automation, settlement: .settled(through: 500)), isLive: true))
        #expect(try !isSettled(now, ThreadMarks(purpose: .probe)))
        #expect(try isSettled(threshold, ThreadMarks(purpose: .probe)))

        #expect(try !isSettled(500, ThreadMarks(pinName: "Keep")))
        #expect(try !isSettled(500, ThreadMarks(pinName: "Keep", settlement: .settled(through: 900_000))))
        #expect(try !isSettled(500, ThreadMarks(markedUnread: true)))
        #expect(try !isSettled(500, readBaseline: 100))
        #expect(try !isSettled(500, ThreadMarks(settlement: .settled(through: 900_000)), readBaseline: 100))
        #expect(try !isSettled(500, isLive: true))
        #expect(try !isSettled(500, ThreadMarks(settlement: .settled(through: 900_000)), schemaVersion: 1))
        #expect(ConversationMarksReplica().effective.isSettled(try thread("t", completedAt: 500), isLive: false, at: now) == false)
    }

    @Test func aGatewayWithoutSettlementDropsPendingSettlementButKeepsOtherChanges() {
        var replica = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 0, threads: [:]))
        replica.record(.settle(threadID: "a", through: 10))
        replica.record(.pin(threadID: "b", name: "Keep"))
        replica.record(.unsettle(threadID: "c", through: 20))
        #expect(replica.effective.settlement(of: "a") == .settled(through: 10))

        replica.replaceAcknowledged(ConversationMarks(schemaVersion: 2, revision: 2, readBaseline: 0, threads: [:]))
        #expect(replica.pending.count == 3)

        replica.replaceAcknowledged(ConversationMarks(schemaVersion: 1, revision: 2, readBaseline: 0, threads: [:]))
        #expect(replica.pending.map(\.change) == [.pin(threadID: "b", name: "Keep")])
        #expect(!replica.effective.offersSettlement)
    }

    @Test func aReplicaIsUnknownUntilReadAndLayersPendingChangesOnTop() throws {
        var replica = ConversationMarksReplica()
        #expect(replica.isReadStateKnown == false)
        #expect(replica.effective.isUnread(try thread("a", completedAt: 900)) == false)

        replica.record(.pin(threadID: "a", name: "Keep"))
        replica.record(.markAllRead(through: 20))
        replica.record(.markAllRead(through: 30))
        #expect(replica.pending.map(\.change) == [.pin(threadID: "a", name: "Keep"), .markAllRead(through: 30)])
        #expect(replica.effective.pinName(for: "a") == "Keep")

        replica.replaceAcknowledged(ConversationMarks(schemaVersion: 1, revision: 1, readBaseline: 5, threads: [:]))
        #expect(replica.effective.readBaseline == 30)
        let sent = Array(replica.pending.prefix(1))
        replica.acknowledge(sent, delta: ConversationMarks(schemaVersion: 1, revision: 2, readBaseline: 5, threads: [
            "a": ThreadMarks(revision: 2, pinName: "Keep"),
        ]))
        #expect(replica.pending.map(\.change) == [.markAllRead(through: 30)])
        #expect(replica.acknowledged?.pinName(for: "a") == "Keep")
    }

    @Test func pendingChangesAreBounded() {
        var replica = ConversationMarksReplica()
        for index in 0..<(ConversationMarksReplica.pendingLimit + 5) {
            replica.record(.markRead(threadID: "t\(index)", through: 1))
        }
        #expect(replica.pending.count == ConversationMarksReplica.pendingLimit)
        #expect(replica.pending.first?.change == .markRead(threadID: "t5", through: 1))
    }

    @Test func retirementKeepsOnlyPendingEditsAndInvalidatesReadCoverage() throws {
        var host = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 9, readBaseline: 100,
            threads: ["shared": ThreadMarks(pinName: "Host pin")]))
        host.record(.pin(threadID: "host-local", name: "Host edit"))
        let hostEdit = try #require(host.pending.first)
        var retired = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 4, readBaseline: 200,
            threads: ["shared": ThreadMarks(pinName: "Old pin"), "retired": ThreadMarks(pinName: "Adopted pin")]))
        retired.record(.markAllRead(through: 300))
        retired.record(.markUnread(threadID: "retired"))
        let sourceEdits = retired.pending
        let account = UUID()
        try host.adopt(retired, sourceID: account)
        let once = host
        try host.adopt(retired, sourceID: account)
        #expect(host == once)
        #expect(!host.isReadStateKnown)
        #expect(host.effective.readBaseline == .max)
        #expect(host.pending.map(\.id) == sourceEdits.map(\.id) + [hostEdit.id])
        #expect(host.pending.map(\.change) == [.markRetiredScopeRead(scopeID: account.uuidString.lowercased(), through: 300),
            .markUnread(threadID: "retired"), hostEdit.change])
        #expect(host.effective.pinName(for: "shared") == "Host pin")
        #expect(host.effective.pinName(for: "retired") == "Adopted pin")
        #expect(host.acknowledged?.revision == 9)
        #expect(host.acknowledged?.threads["retired"]?.revision == 0)
    }

    @Test func theDefaultScopeIsRetiredExactlyOnceAndSurvivesPersistence() throws {
        var replica = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 9, readBaseline: 300, threads: [:]))
        replica.record(.markAllRead(through: 350))
        let id = try #require(replica.pending.first?.id)
        replica.retireDefaultScope()
        replica = try JSONDecoder().decode(ConversationMarksReplica.self, from: JSONEncoder().encode(replica))
        replica.record(.markAllRead(through: 400))
        replica.retireDefaultScope()
        #expect(replica.pending.first == .init(id: id, change: .markRetiredScopeRead(scopeID: "default", through: 350)))
        #expect(replica.pending.last?.change == .markAllRead(through: 400))
        replica.receive(.init(schemaVersion: 2, revision: 10, readBaseline: 300, threads: [:]))
        #expect(!replica.isReadStateKnown)
        replica.replaceAcknowledged(.init(schemaVersion: 2, revision: 11, readBaseline: 100, threads: [:], supportsRetiredScopeRead: true))
        #expect(replica.isReadStateKnown)
        #expect(replica.acknowledged?.readBaseline == 100)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(replica.pending[0].change)) as? [String: Any])
        #expect(wire["op"] as? String == "markRetiredScopeRead")
        #expect(wire["scopeId"] as? String == "default")
        #expect(wire["through"] as? Int == 350)
    }

    @Test func retirementPreservesUnknownHostStateAndRejectsOverflowWithoutDroppingChanges() throws {
        var host = ConversationMarksReplica()
        var retired = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 4, readBaseline: 200, threads: [
            "retired": ThreadMarks(pinName: "Keep"),
        ]))
        retired.record(.markAllRead(through: 300))
        try host.adopt(retired, sourceID: UUID())
        #expect(!host.isReadStateKnown)
        #expect(host.effective.pinName(for: "retired") == "Keep")
        for index in 0..<ConversationMarksReplica.pendingLimit { host.record(.markUnread(threadID: "host-\(index)")) }
        let before = host
        #expect(throws: ConversationMarksReplica.AdoptionFailure.self) {
            try host.adopt(retired, sourceID: UUID())
        }
        #expect(host == before)
    }

    @Test func settlingCoversTheShownRequestsAndItsUndoRestoresPinsAndUnread() throws {
        let pinned = try thread("pinned", completedAt: 300)
        let unread = try thread("unread", completedAt: 400)
        let read = try thread("read", completedAt: 50)
        var child = try thread("child", completedAt: 500)
        child.agentRelation = .init(parentThreadId: "pinned", parentAccountId: nil, agentId: "launcher:run")
        let marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 100, threads: [
            "pinned": ThreadMarks(revision: 1, seenThrough: 300, pinName: "Keep"),
        ])

        let settling = marks.settling([pinned, unread, read, child], newestRequestAt: ["unread": 10, "read": 900])
        #expect(settling.edits == [
            ConversationSettlementEdit(threadID: "pinned", changes: [.settle(threadID: "pinned", through: 300)]),
            ConversationSettlementEdit(threadID: "unread", changes: [.settle(threadID: "unread", through: 400)]),
            ConversationSettlementEdit(threadID: "read", changes: [.settle(threadID: "read", through: 900)]),
        ])
        #expect(settling.undo == [
            ConversationSettlementEdit(threadID: "pinned", changes: [.unsettle(threadID: "pinned", through: 300),
                                                                     .pin(threadID: "pinned", name: "Keep")]),
            ConversationSettlementEdit(threadID: "unread", changes: [.unsettle(threadID: "unread", through: 400),
                                                                     .markUnread(threadID: "unread")]),
            ConversationSettlementEdit(threadID: "read", changes: [.unsettle(threadID: "read", through: 50)]),
        ])

        let settled = settling.edits.flatMap(\.changes).reduce(marks) { $0.applying($1) }
        #expect([pinned, unread, read].allSatisfy { settled.isSettled($0, isLive: false, at: 1_000) })
        #expect(settled.pinName(for: "pinned") == nil)
        #expect(settled.coversRequest(madeAt: 900, in: read, at: 1_000))
        #expect(!settled.coversRequest(madeAt: 901, in: read, at: 1_000))

        let restored = settling.undo.flatMap(\.changes).reduce(settled) { $0.applying($1) }
        #expect(restored.pinName(for: "pinned") == "Keep")
        #expect(restored.isUnread(unread))
        #expect(!restored.isUnread(read))
        #expect([pinned, unread, read].allSatisfy { !restored.isSettled($0, isLive: false, at: 1_000) })

        #expect(settled.unsettling([pinned, child]) == [
            ConversationSettlementEdit(threadID: "pinned", changes: [.unsettle(threadID: "pinned", through: 300)]),
        ])
    }

    @Test func aGatewayWithoutSettlementOffersNoSettlementEdits() throws {
        let marks = ConversationMarks(schemaVersion: 1, revision: 1, readBaseline: 100, threads: [:])
        let settling = marks.settling([try thread("a", completedAt: 50)], newestRequestAt: [:])
        #expect(settling.edits.isEmpty)
        #expect(settling.undo.isEmpty)
        #expect(marks.unsettling([try thread("a", completedAt: 50)]).isEmpty)
    }

    @Test func theStoreRoundTripsItsVersionedFileAndSetsAsideCorruptOnes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attention = directory.appending(path: "conversation-attention.json")
        try Data("{}".utf8).write(to: attention)

        let store = ConversationMarksStore(directory: directory)
        guard case .missing = await store.load() else { Issue.record("expected no marks"); return }
        #expect(FileManager.default.fileExists(atPath: attention.path) == false)

        var replica = ConversationMarksReplica()
        replica.retireDefaultScope()
        replica.record(.pin(threadID: "a", name: "Keep"))
        #expect(await store.save(replica))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "conversation-marks.v2.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "conversation-marks.json").path) == false)
        guard case let .stored(loaded) = await ConversationMarksStore(directory: directory).load() else {
            Issue.record("expected stored marks"); return
        }
        #expect(loaded == replica)

        let corrupt = Data("{\"pending\":".utf8)
        try corrupt.write(to: directory.appending(path: "conversation-marks.v2.json"))
        guard case .missing = await store.load() else { Issue.record("expected a fresh start"); return }
        #expect(try Data(contentsOf: directory.appending(path: "conversation-marks.v2.undecodable.json")) == corrupt)
    }

    @Test func theLegacyReplicaIsImportedOnceAndStaysReadableForAnOlderBuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appending(path: "conversation-marks.json")
        var legacy = ConversationMarksReplica(acknowledged: ConversationMarks(schemaVersion: 2, revision: 3, readBaseline: 100,
            threads: ["a": ThreadMarks(revision: 3, pinName: "Acknowledged")]))
        legacy.record(.pin(threadID: "b", name: "Pending"))
        legacy.record(.markRead(threadID: "c", through: 200))
        let legacyData = try JSONEncoder().encode(legacy)
        try legacyData.write(to: legacyURL)

        let store = ConversationMarksStore(directory: directory)
        guard case .stored(var imported) = await store.load() else { Issue.record("expected the legacy replica"); return }
        #expect(!imported.isReadStateKnown)
        #expect(imported.pending == legacy.pending)
        #expect(imported.effective.pinName(for: "a") == "Acknowledged")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "conversation-marks.v2.json").path))

        imported.record(.settle(threadID: "a", through: 300))
        #expect(await store.save(imported))
        guard case let .stored(reloaded) = await ConversationMarksStore(directory: directory).load() else {
            Issue.record("expected the versioned replica"); return
        }
        #expect(reloaded.pending.map(\.change) == [.pin(threadID: "b", name: "Pending"), .markRead(threadID: "c", through: 200),
                                                   .settle(threadID: "a", through: 300)])
        #expect(try Data(contentsOf: legacyURL) == legacyData)

        let corrupt = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let unreadable = Data("{\"pending\":".utf8)
        try unreadable.write(to: corrupt.appending(path: "conversation-marks.json"))
        guard case .missing = await ConversationMarksStore(directory: corrupt).load() else { Issue.record("expected a fresh start"); return }
        #expect(try Data(contentsOf: corrupt.appending(path: "conversation-marks.json")) == unreadable)
    }

    private func thread(_ id: String, completedAt: Int64?) throws -> ConversationHeader {
        let fields: [String: Any] = completedAt.map { ["lastTurnCompletedAt": $0] } ?? [:]
        return try ThreadFixture.basic(id, updatedAt: completedAt ?? 0, fields: fields)
    }
}
