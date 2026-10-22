import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationAgentsTests {
    private func thread(_ fields: [String: Any]) throws -> ConversationHeader {
        let base: [String: Any] = ["id": "worker", "preview": "<agent_message>payload</agent_message>",
            "modelProvider": "openai", "createdAt": 1, "updatedAt": 2, "cwd": "/tmp", "cliVersion": "test", "source": "cli"]
        return try ThreadFixture.decode(base.merging(fields) { _, new in new })
    }

    @Test func knownDelegationSurvivesPersistenceAndHistoryReplacement() throws {
        let original = try thread(["name": "Check launcher", "parentThreadId": "root", "canAcceptDirectInput": false,
            "agentRelation": ["parentThreadId": "root", "agentId": "launcher:run-1"]])
        let restored = try JSONDecoder().decode(ConversationHeader.self, from: JSONEncoder().encode(original))
        #expect(restored.isDelegatedAgent)
        #expect(restored.canAcceptDirectInput == false)
        #expect(!restored.acceptsDirectInput)
        #expect(try thread(["parentThreadId": "root"]).acceptsDirectInput == false)
        #expect(try thread(["agentRelation": ["parentThreadId": "root", "agentId": "launcher:run"]]).acceptsDirectInput)
        #expect(restored.displayTitle == "Check launcher")
        let merged = ConversationHeaderStore.merging(current: [restored], fetched: [try thread([:])])
        #expect(merged.first?.agentRelation?.agentId == "launcher:run-1")
        #expect(merged.first?.isDelegatedAgent == true)
    }

    @Test func aSpawnedSubAgentSourceDefinesTheNativeParent() throws {
        let spawned = try thread(["source": ["subAgent": ["thread_spawn": ["parent_thread_id": "root", "depth": 1]]]])
        let anonymous = try thread(["source": ["subAgent": ["thread_spawn": ["depth": 1]]]])
        #expect(spawned.isNativeAgent)
        #expect(spawned.agentParentThreadID == "root")
        #expect(anonymous.isNativeAgent)
        #expect(anonymous.agentParentThreadID == nil)
        #expect(try thread(["source": "cli"]).agentParentThreadID == nil)
    }

    @Test func xmlPreviewNeverEstablishesOwnership() throws {
        let unknown = try thread([:])
        #expect(!unknown.isDelegatedAgent)
        #expect(unknown.displayTitle == unknown.preview)
        #expect(ConversationSidebarProjection.title(for: try thread(["name": "Explicit name"]), pinnedName: "Pinned") == "Pinned")
    }

    @Test func valuesFromANewerGatewayDecodeAsUnknownInsteadOfFailingThePayload() throws {
        let agentJSON = Data(#"""
        {"id": "a", "ownerThreadId": "root", "provider": "gemini", "source": "native", "title": "a", "state": "paused",
         "capabilities": {"inspect": true, "openConversation": false, "message": false, "continueWork": false, "stop": false, "askParent": false}}
        """#.utf8)
        let agent = try JSONDecoder().decode(ConversationAgent.self, from: agentJSON)
        #expect(agent.provider.displayName == "gemini")
        #expect(agent.state == .unknown)
        let output = try JSONDecoder().decode(ConversationAgentOutput.self,
            from: Data(#"{"messages": [{"role": "tool", "text": "x"}, {"role": "user", "text": "y"}], "truncated": false}"#.utf8))
        #expect(output.messages.map(\.role) == [.init(rawValue: "tool"), .user])
    }
}
