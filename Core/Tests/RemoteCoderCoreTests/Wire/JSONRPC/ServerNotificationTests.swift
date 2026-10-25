import Foundation
import Testing
@testable import RemoteCoderCore

struct ServerNotificationTests {
    private func decode(_ json: String) throws -> ServerNotification {
        let frame = Data(json.utf8)
        let method = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])["method"] as? String
        return ServerNotification.decode(method: try #require(method), frame: frame)
    }

    @Test func aCompletedItemCarriesItsAddressPositionAndPayload() throws {
        let notification = try decode("""
        {"method":"item/completed","params":{"threadId":" thread ","turnId":"turn-1",
         "item":{"type":"agentMessage","id":"a","text":"Hi"},
         "startedAtOrdinal":4,"startedAtMs":1500,"completedAtMs":2500}}
        """)

        guard case .itemCompleted(let event) = notification else { Issue.record("Expected item/completed"); return }
        #expect(event.address == .init(threadID: "thread", turnID: "turn-1"))
        #expect(event.item == .agentMessage(id: "a", text: "Hi"))
        #expect(event.startedAtOrdinal == 4)
        #expect(event.startedAtMs == 1500)
        #expect(event.completedAtMs == 2500)
        #expect(event.encodedBytes > 0)
    }

    @Test func aTurnIdentityComesFromTheTurnObjectWhenNoTurnIdIsSent() throws {
        let notification = try decode(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"7","status":"failed","completedAt":160}}}"#)

        guard case .turnCompleted(let completion) = notification else { Issue.record("Expected turn/completed"); return }
        #expect(completion.address == .init(threadID: "t", turnID: "7"))
        #expect(completion.status == .failed)
        #expect(completion.completedAt == 160)
        #expect(completion.errorMessage == nil)
    }

    @Test func aFailedTurnCarriesItsErrorMessage() throws {
        let notification = try decode(#"{"method":"turn/completed","params":{"threadId":"t","turnId":"1","turn":{"status":"failed","error":{"message":"Rate limit reached"}}}}"#)

        guard case .turnCompleted(let completion) = notification else { Issue.record("Expected turn/completed"); return }
        #expect(completion.status == .failed)
        #expect(completion.errorMessage == "Rate limit reached")
    }

    @Test func aReadyNotificationCarriesTheNotificationBaseline() throws {
        guard case .daemonReady(let ready) = try decode(#"{"method":"daemon/ready","params":{"notificationEpoch":"e1","notificationSequence":41}}"#) else {
            Issue.record("Expected daemon/ready"); return
        }
        #expect(ready == .init(epoch: "e1", sequence: 41, cancelRequest: false, providerHealth: nil))
        guard case .malformed("daemon/ready", .none, _) = try decode(#"{"method":"daemon/ready","params":{"notificationEpoch":"e1"}}"#) else {
            Issue.record("Expected a ready notification without a sequence to be malformed"); return
        }
    }

    @Test func aReadyNotificationCarriesProviderHealth() throws {
        guard case .daemonReady(let ready) = try decode(#"""
        {"method":"daemon/ready","params":{"notificationEpoch":"e1","notificationSequence":3,
         "providers":{"codex":{"state":"unavailable","reason":"Codex sign-in needed"},"claude":{"state":"ready"}}}}
        """#) else {
            Issue.record("Expected daemon/ready"); return
        }
        #expect(ready.providerHealth == ProviderHealth([.codex: .unavailable(reason: "Codex sign-in needed"), .claude: .ready]))
    }

    @Test func aCallChangeCarriesTheCallAndItsState() throws {
        let callID = UUID()
        guard case .callChanged(let change) = try decode(#"{"method":"calls/changed","params":{"callId":"\#(callID.uuidString)","state":"ending"}}"#) else {
            Issue.record("Expected calls/changed"); return
        }
        #expect(change == .init(callId: callID, state: .ending))
        guard case .malformed("calls/changed", .none, _) = try decode(#"{"method":"calls/changed","params":{"callId":"not-a-uuid","state":"ending"}}"#) else {
            Issue.record("Expected an invalid call id to be malformed"); return
        }
    }

    @Test func aTurnWithoutIdentityIsNotRouted() throws {
        guard case .unknown("turn/started") = try decode(#"{"method":"turn/started","params":{"threadId":"t"}}"#) else {
            Issue.record("Expected an unaddressed turn notification to stay unknown"); return
        }
    }

    @Test func deltasCarryTheirBlockIndex() throws {
        let scope = #""threadId":"t","turnId":"1","itemId":"r","delta":"x""#
        guard case .reasoningSummaryDelta(let summary) = try decode(#"{"method":"item/reasoning/summaryTextDelta","params":{\#(scope),"summaryIndex":2}}"#),
              case .reasoningTextDelta(let content) = try decode(#"{"method":"item/reasoning/textDelta","params":{\#(scope),"contentIndex":3}}"#),
              case .agentMessageDelta(let message) = try decode(#"{"method":"item/agentMessage/delta","params":{\#(scope)}}"#) else {
            Issue.record("Expected typed deltas"); return
        }
        #expect(summary.index == 2)
        #expect(content.index == 3)
        #expect(message.index == nil)
        #expect(message.delta == "x")
    }

    @Test func aDiffUpdateFallsBackToTheExplanation() throws {
        guard case .turnDiffUpdated(let diff) = try decode(#"{"method":"turn/diff/updated","params":{"threadId":"t","turnId":"1","diff":"+a"}}"#),
              case .turnPlanUpdated(let plan) = try decode(#"{"method":"turn/plan/updated","params":{"threadId":"t","turnId":"1","explanation":"Why"}}"#) else {
            Issue.record("Expected typed updates"); return
        }
        #expect(diff.text == "+a")
        #expect(plan.text == "Why")
    }

    @Test func threadClosedAndQuestionChangesAreTyped() throws {
        guard case .threadClosed(let closed) = try decode(#"{"method":"thread/closed","params":{"threadId":"t"}}"#),
              case .questionsChanged(let changed) = try decode(#"{"method":"conversation/questions/changed","params":{"threadId":"t","epoch":"e","revision":1790330861099,"itemIds":["a","b"]}}"#) else {
            Issue.record("Expected typed thread and question notifications"); return
        }
        #expect(closed == "t")
        #expect(changed == .init(threadID: "t", epoch: "e", revision: 1_790_330_861_099, itemIDs: ["a", "b"]))
    }

    @Test func historyInvalidationSaysWhetherTheThreadWasRemoved() throws {
        guard case .threadHistoryInvalidated("t", let deleted) = try decode(#"{"method":"thread/deleted","params":{"threadId":"t"}}"#),
              case .threadHistoryInvalidated("t", let reverted) = try decode(#"{"method":"thread/reverted","params":{"threadId":"t"}}"#) else {
            Issue.record("Expected history invalidations"); return
        }
        #expect(deleted)
        #expect(!reverted)
    }

    @Test func archiveChangesAndMarkDeltasAreTyped() throws {
        guard case .threadArchived("t", let archived) = try decode(#"{"method":"thread/archived","params":{"threadId":"t"}}"#),
              case .threadArchived("t", let unarchived) = try decode(#"{"method":"thread/unarchived","params":{"threadId":"t"}}"#),
              case .conversationMarksChanged(let delta) = try decode(#"{"method":"conversation/marks/changed","params":{"revision":7,"readBaseline":100,"threads":{"t":{"revision":7,"pinName":"Keep","purpose":"probe"}}}}"#) else {
            Issue.record("Expected archive and marks notifications"); return
        }
        #expect(archived)
        #expect(!unarchived)
        #expect(delta == ConversationMarks(schemaVersion: 1, revision: 7, readBaseline: 100, threads: [
            "t": ThreadMarks(revision: 7, pinName: "Keep", purpose: .probe),
        ]))
    }

    @Test func favoriteChangesCarryTheHostsWholeList() throws {
        guard case .directoryFavoritesChanged(let favorites) = try decode(
            #"{"method":"directory/favorites/changed","params":{"revision":2,"paths":["/work/B","/work/A"]}}"#
        ) else {
            Issue.record("Expected a favorites notification"); return
        }
        #expect(favorites == DirectoryFavorites(revision: 2, paths: ["/work/B", "/work/A"]))
    }

    @Test func preferenceChangesCarryEveryEntryWithItsVersion() throws {
        guard case .preferencesChanged(let preferences) = try decode(
            #"{"method":"preferences/changed","params":{"entries":{"ttsAutoSpeakEnabled":{"value":true,"updatedAt":1792240000000,"device":"phone"}}}}"#
        ) else {
            Issue.record("Expected a preferences notification"); return
        }
        #expect(preferences == PreferenceDocument(entries: [
            "ttsAutoSpeakEnabled": PreferenceEntry(value: .bool(true), updatedAt: 1_792_240_000_000, device: "phone"),
        ]))
    }

    @Test func transportErrorsKeepTheirByteCounts() throws {
        let notification = try decode(#"{"method":"daemon/transportError","params":{"kind":"messageTooLarge","actualBytes":33000000,"limitBytes":24000000}}"#)

        guard case .transportError(let error) = notification else { Issue.record("Expected a transport error"); return }
        #expect(error == .init(kind: "messageTooLarge", actualBytes: 33_000_000, limitBytes: 24_000_000))
    }

    @Test func aBrokenSettingsPayloadIsMalformedAndAnUnknownMethodIsNot() throws {
        guard case .malformed("thread/settings/updated", nil, _) = try decode(#"{"method":"thread/settings/updated","params":{"threadId":"t"}}"#),
              case .unknown("thread/started") = try decode(#"{"method":"thread/started","params":{}}"#) else {
            Issue.record("Expected malformed settings and an unknown method"); return
        }
    }

    @Test func aBrokenTurnPayloadIsMalformedAndKeepsItsAddress() throws {
        let scope = #""threadId":"t","turnId":"1""#
        guard case .malformed("item/completed", let itemAddress, let itemReason) = try decode(#"{"method":"item/completed","params":{\#(scope),"item":{"type":"agentMessage","id":"a"}}}"#),
              case .malformed("item/agentMessage/delta", let deltaAddress, _) = try decode(#"{"method":"item/agentMessage/delta","params":{\#(scope),"delta":"x"}}"#) else {
            Issue.record("Expected malformed turn payloads"); return
        }
        #expect(itemAddress == .init(threadID: "t", turnID: "1"))
        #expect(deltaAddress == .init(threadID: "t", turnID: "1"))
        #expect(itemReason.contains("text"))
    }

    @Test func notificationsBuiltFromJSONDecodeLikeWireFrames() throws {
        let params: JSONValue = .object(["threadId": .string("t"), "turnId": .string("1"), "itemId": .string("a"), "delta": .string("Hi")])

        guard case .agentMessageDelta(let delta) = ServerNotification.decode(method: "item/agentMessage/delta", params: params) else {
            Issue.record("Expected a typed delta"); return
        }
        #expect(delta.address == .init(threadID: "t", turnID: "1"))
        #expect(delta.delta == "Hi")
    }
}
