import Foundation
import Testing
@testable import RemoteCoderCore

struct ClusterAgentRelationTests {
    @Test func ownerRowsReplaceStubsInEitherArrivalOrderWithoutCollidingAcrossHosts() throws {
        let host = UUID()
        let other = UUID()
        let parent = UUID()
        let stub = try decode([
            "kind": "remote_intent", "jobId": "job", "ownerHostId": host.uuidString,
            "intentState": "unknown", "parent": ["hostId": parent.uuidString, "threadId": "parent"],
            "createdAt": "2026-10-28T10:00:00Z"
        ])
        let real = try decode(row(host: host, parent: parent))
        let separate = try decode(row(host: other, parent: parent))
        #expect(stub.state == .unknown)
        #expect(stub.parent?.address == .init(hostID: parent, threadID: "parent"))
        for input in [[stub, real, separate], [real, stub, separate]] {
            let result = ConversationAgentsProjection.merge(input)
            #expect(result.count == 2)
            #expect(result.first?.isStub == false)
            #expect(result.first?.address(localHostID: parent) == .init(hostID: host, threadID: "child"))
        }
        var removedFields: [String: Any] = ["kind": "remote_intent", "jobId": "removed", "ownerHostId": host.uuidString,
            "intentState": "removed", "parent": ["hostId": parent.uuidString, "threadId": "parent"]]
        removedFields["createdAt"] = "2026-10-28T10:00:00Z"
        #expect(try decode(removedFields).state == .removed)
    }

    @Test func currentParentTagOverridesSpawnProvenanceIncludingPromotion() throws {
        let parent = UUID()
        let fields: [String: Any] = ["id": "worker", "preview": "", "createdAt": 1, "updatedAt": 2,
            "cwd": "/tmp", "source": ["subAgent": ["thread_spawn": ["parent_thread_id": "original"]]],
            "parent": ["hostId": parent.uuidString, "threadId": "current"]]
        let moved = try ThreadFixture.decode(fields)
        #expect(moved.agentRelation?.parentHostID == parent)
        #expect(moved.agentParentThreadID == "current")
        #expect(moved.isDelegatedAgent)
        var promoted = fields
        promoted["parent"] = NSNull()
        let root = try ThreadFixture.decode(promoted)
        #expect(!root.isDelegatedAgent)
        #expect(root.agentParentThreadID == nil)
        let stored = try JSONDecoder().decode(ConversationHeader.self, from: JSONEncoder().encode(root))
        #expect(!stored.isDelegatedAgent)
    }

    private func row(host: UUID, parent: UUID) -> [String: Any] {
        ["id": "launcher:job", "jobId": "job", "ownerHostId": host.uuidString, "ownerThreadId": "parent", "threadId": "child",
         "provider": "codex", "source": "launcher", "title": "Child", "state": "working",
         "parent": ["hostId": parent.uuidString, "threadId": "parent"],
         "capabilities": ["inspect": true, "openConversation": true, "message": false,
                          "continueWork": false, "stop": false, "askParent": false]]
    }

    private func decode(_ fields: [String: Any]) throws -> ConversationAgent {
        try JSONDecoder().decode(ConversationAgent.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
