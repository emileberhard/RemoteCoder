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
            "lastActiveAt": 1_793_181_600
        ])
        let real = try decode(row(host: host, parent: parent))
        let separate = try decode(row(host: other, parent: parent))
        #expect(stub.state == .unknown)
        #expect(stub.lastActiveAt == 1_793_181_600)
        #expect(stub.parent?.address == .init(hostID: parent, threadID: "parent"))
        for input in [[stub, real, separate], [real, stub, separate]] {
            let result = ConversationAgentsProjection.merge(input)
            #expect(result.count == 2)
            #expect(result.first?.isStub == false)
            #expect(result.first?.address(localHostID: parent) == .init(hostID: host, threadID: "child"))
        }
        var removedFields: [String: Any] = ["kind": "remote_intent", "jobId": "removed", "ownerHostId": host.uuidString,
            "intentState": "removed", "parent": ["hostId": parent.uuidString, "threadId": "parent"]]
        removedFields["lastActiveAt"] = 1_793_181_600
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

    @Test func parentTagsRoundTripAbsentRootAndChildWithoutContradictoryFlags() throws {
        let parent = ClusterParent(hostId: UUID(), threadId: "parent")
        let fields: [String: Any] = ["id": "worker", "preview": "", "createdAt": 1, "updatedAt": 2, "cwd": "/tmp", "source": "cli"]
        let thread = try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(thread.parentTag == .absent)
        for tag in [CodexAppServerV2.ParentTag.absent, .root, .child(parent)] {
            var updated = thread
            updated.parentTag = tag
            let encoded = try JSONEncoder().encode(updated)
            #expect(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: encoded).parentTag == tag)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if tag == .absent { #expect(object["parent"] == nil) }
            if tag == .root { #expect(object["parent"] is NSNull) }
        }
    }

    @Test func intentRowsUseTheSameEpochTimeAndUnknownStateAsRealRows() throws {
        let host = UUID(), parent = UUID()
        var fields = row(host: host, parent: parent)
        fields["lastActiveAt"] = 1_793_181_600
        let real = try decode(fields)
        let stub = try decode(["kind": "remote_intent", "jobId": "job", "ownerHostId": host.uuidString,
            "intentState": "future", "parent": ["hostId": parent.uuidString, "threadId": "parent"],
            "lastActiveAt": 1_793_181_600])
        #expect(stub.lastActiveAt == real.lastActiveAt)
        #expect(stub.intentState == .unknown)
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
