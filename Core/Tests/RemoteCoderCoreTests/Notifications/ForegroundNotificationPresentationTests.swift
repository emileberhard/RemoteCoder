import Foundation
import Testing
@testable import RemoteCoderCore

struct ForegroundNotificationPresentationTests {
    @Test func futureSourcesKeepTheAlertAndItsReadableIdentity() async throws {
        let encoded = #"{"eventID":"event","source":"future-provider","outcome":"success","sessionID":"thread","hostID":"AAAAAAAA-0000-0000-0000-000000000001","promptPreview":"Prompt","messagePreview":"Done","createdAtUnixSeconds":1790000000}"#
        let delivery = await ForegroundNotificationPresentation.prepare(payloadJSON: encoded, title: "Future provider finished", body: "Done")
        #expect(delivery.payload?.source == .unknown)
        #expect(delivery.payload?.sessionID == "thread")
        #expect(delivery.title == "Future provider finished")
        #expect(delivery.decodingFailure == nil)
    }

    @Test(arguments: ["codex", "claude"])
    func retiredEnrollmentSuppressionUsesOnlyHostAndThread(provider: String) throws {
        let host = UUID()
        let event = try JSONDecoder().decode(TaskCompletionNotificationPayload.self, from: Data("""
            {"eventID":"event","source":"\(provider)","outcome":"success","sessionID":"thread","hostID":"\(host)",
             "promptPreview":"Prompt","messagePreview":"Done","createdAtUnixSeconds":1790000000,
             "accountID":"AAAAAAAA-0000-0000-0000-000000000001","accountGeneration":2}
            """.utf8))
        let matchingConversation = ForegroundNotificationPresentation.isOpen(event, address: ConversationAddress(hostID: host, threadID: "thread"))
        #expect(matchingConversation)
        let otherHost = ForegroundNotificationPresentation.isOpen(event, address: ConversationAddress(hostID: UUID(), threadID: "thread"))
        let otherThread = ForegroundNotificationPresentation.isOpen(event, address: ConversationAddress(hostID: host, threadID: "other"))
        #expect(!otherHost)
        #expect(!otherThread)
    }

    @Test func eventDeduplicationSurvivesRestorationAndDistinguishesOwners() {
        let host = UUID()
        let event = payload(hostID: host)
        var ledger = ForegroundNotificationPresentation.Ledger()
        let first = ledger.consume(event)
        let duplicate = ledger.consume(event)
        #expect(first)
        #expect(!duplicate)
        var restored = ForegroundNotificationPresentation.Ledger(eventIDs: ledger.eventIDs)
        let old = restored.consume(event)
        let otherHost = restored.consume(payload(hostID: UUID()))
        let legacyID = "\(host)|AAAAAAAA-0000-0000-0000-000000000001|2|event"
        var legacy = ForegroundNotificationPresentation.Ledger(eventIDs: [legacyID])
        let legacyDuplicate = legacy.consume(event)
        #expect(!old)
        #expect(otherHost && !legacyDuplicate)
        for index in 0..<300 { _ = restored.consume(payload(eventID: "event-\(index)", hostID: host)) }
        #expect(restored.eventIDs.count == 256)
        let newest = restored.consume(payload(eventID: "event-299", hostID: host))
        #expect(!newest)
    }

    @Test func emptyEventsDoNotDeduplicateButNamedEventsDo() {
        var ledger = ForegroundNotificationPresentation.Ledger()
        let first = ledger.consume(payload(eventID: ""))
        let second = ledger.consume(payload(eventID: ""))
        let host = UUID()
        let named = payload(hostID: host)
        let third = ledger.consume(named)
        let fourth = ledger.consume(named)
        #expect(first && second && third && !fourth)
        #expect(ledger.eventIDs.count == 1)
    }

    private func payload(eventID: String = "event",
                         hostID: UUID = UUID()) -> TaskCompletionNotificationPayload {
        TaskCompletionNotificationPayload(eventID: eventID, source: .codex, outcome: .success,
            conversationID: nil, sessionID: "thread", hostID: hostID, promptPreview: "Prompt",
            messagePreview: "Done", workingDirectory: nil, createdAtUnixSeconds: 1_790_000_000)
    }
}
