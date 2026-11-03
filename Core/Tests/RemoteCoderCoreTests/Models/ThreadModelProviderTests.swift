import Foundation
import Testing
@testable import RemoteCoderCore

struct ThreadModelProviderTests {
    @Test func threadsIdentifyNativeAndExternalRoutes() throws {
        let header = try ThreadFixture.basic("copilot-thread", updatedAt: 1, fields: ["modelProvider": "copilot"])
        let restored = try JSONDecoder().decode(ConversationHeader.self, from: JSONEncoder().encode(header))

        #expect(ThreadModelProvider(restored.modelProvider, threadID: restored.id) == .external(id: "copilot"))
        #expect(ThreadModelProvider("copilot", threadID: "t")?.notice == "Runs on Copilot")
        #expect(ThreadModelProvider("openai", threadID: "t") == .native)
        #expect(ThreadModelProvider("openai", threadID: "t")?.notice == nil)
        #expect(ThreadModelProvider("claude", threadID: "claude_t") == .native)
        #expect(ThreadModelProvider("copilot", threadID: "claude_t") == .external(id: "copilot"))
        #expect(ThreadModelProvider(nil, threadID: "t") == nil)
    }
}
