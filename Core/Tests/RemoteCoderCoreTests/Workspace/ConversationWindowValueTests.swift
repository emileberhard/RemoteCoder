import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationWindowValueTests {
    private let host = UUID()
    private let account = UUID()

    @Test func aConversationValueSurvivesEncodingWithItsHost() throws {
        let value = ConversationWindowValue.conversation(
            ConversationAddress(hostID: host, threadID: "thread-1"))
        let decoded = try JSONDecoder().decode(ConversationWindowValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func aNewChatValueSurvivesEncodingWithItsSlot() throws {
        let value = ConversationWindowValue.newChat(slot: UUID())
        let decoded = try JSONDecoder().decode(ConversationWindowValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func legacyEnrollmentWindowsResolveToOneHostConversation() throws {
        let legacy = Data("{\"hostID\":\"\(host)\",\"threadID\":\"thread-1\",\"accountID\":\"\(account)\"}".utf8)
        let decoded = try JSONDecoder().decode(ConversationAddress.self, from: legacy)
        #expect(decoded == ConversationAddress(hostID: host, threadID: "thread-1"))
        #expect(decoded.id == "\(host)|thread-1")
        let target = try JSONDecoder().decode(ExecutionTarget.self, from: legacy)
        #expect(target == ExecutionTarget(hostID: host))
    }

}
