import Foundation
import Testing

@testable import RemoteCoderCore

struct DispatchPolicyTests {
    private func bytes<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test(arguments: [
        ("item/commandExecution/requestApproval", #"{"decision":"decline"}"#),
        ("item/fileChange/requestApproval", #"{"decision":"decline"}"#),
        ("item/permissions/requestApproval", #"{"permissions":{},"scope":"turn"}"#),
        ("item/tool/call", #"{"contentItems":[],"success":false}"#),
    ])
    func declineReplyBytesAreUnchanged(method: String, expected: String) throws {
        let reply = try #require(DispatchPolicy.declineReplies[method])

        #expect(try bytes(reply) == expected)
    }

    @Test func onlyTheFourKnownRequestsAreDeclined() {
        #expect(Set(DispatchPolicy.declineReplies.keys) == [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "item/tool/call",
        ])
    }

    @Test func policyConstantsKeepTheirWireBytes() throws {
        #expect(try bytes(DispatchPolicy.approvalPolicy) == #""never""#)
        #expect(try bytes(DispatchPolicy.threadSandbox) == #""danger-full-access""#)
        #expect(try bytes(DispatchPolicy.turnSandbox) == #"{"type":"dangerFullAccess"}"#)
    }
}
