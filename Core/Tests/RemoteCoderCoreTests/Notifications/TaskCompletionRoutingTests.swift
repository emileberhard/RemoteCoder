import Foundation
import Testing
@testable import RemoteCoderCore

/// Completion notifications name their host, so ownership is exact: a host
/// that is no longer configured has no owner, whatever its thread ids were.
struct TaskCompletionRoutingTests {
    private let mini = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let book = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    @Test func theNamedHostResolvesOnlyWhileItIsStillConfigured() {
        let targets = [ExecutionTarget(hostID: mini), ExecutionTarget(hostID: book)]
        #expect(
            TaskCompletionRouting.resolve(payloadHostID: book, targets: targets)
                == ExecutionTarget(hostID: book)
        )
        #expect(TaskCompletionRouting.resolve(payloadHostID: UUID(), targets: targets) == nil)
    }

    @Test func payloadsWithoutAHostIDDoNotDecode() {
        let json = """
        {"eventID":"evt-1","source":"codex","outcome":"success","sessionID":"0199",
         "promptPreview":"Ship it","messagePreview":"Done","createdAtUnixSeconds":1757500000}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TaskCompletionNotificationPayload.self, from: Data(json.utf8))
        }
    }

    @Test func questionAlertsCarryTheItemAndNoOutcome() throws {
        let json = """
        {"eventID":"question:0199:call_q","source":"codex","sessionID":"0199","hostID":"AAAAAAAA-0000-0000-0000-000000000001","promptPreview":"Ship it",
         "messagePreview":"Which one? (+1 more)","createdAtUnixSeconds":1757500000,"questionItemID":"call_q"}
        """
        let payload = try JSONDecoder().decode(TaskCompletionNotificationPayload.self, from: Data(json.utf8))
        #expect(payload.questionItemID == "call_q")
        #expect(payload.outcome == nil)
        #expect(payload.sessionID == "0199")
    }
}
