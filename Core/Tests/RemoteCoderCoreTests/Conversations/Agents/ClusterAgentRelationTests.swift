import Foundation
import Testing
@testable import RemoteCoderCore

struct ClusterAgentRelationTests {
    @Test func ownerRowsReplaceStubsInEitherArrivalOrderWithoutCollidingAcrossHosts() throws {
        let host = UUID()
        let other = UUID()
        let parent = UUID()
        let stub = try decode(intent(host: host, parent: parent, state: "unknown"))
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
        #expect(try decode(intent(host: host, parent: parent, state: "removed")).state == .removed)
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
        let stub = try decode(intent(host: host, parent: parent, state: "future"))
        #expect(stub.lastActiveAt == real.lastActiveAt)
        #expect(stub.intentState == .unknown)
    }

    @Test func intentsRequireTheSameCapabilitiesAsEveryOtherAgentRow() throws {
        var fields = intent(host: UUID(), parent: UUID(), state: "pending")
        fields["capabilities"] = nil
        #expect(throws: DecodingError.self) { try decode(fields) }
    }

    @Test func clusterErrorClassesRetainTheirCoverageMeaning() throws {
        for (name, expected) in [("unavailable", ClusterCoverage.State.unavailable), ("unsupported", .unsupported), ("refused", .refused)] {
            let data: JSONValue = .object(["class": .string(name), "retryable": .bool(false)])
            let error = try #require(GatewayRPCFailure(code: -32600, message: name, data: data))
            #expect(ClusterCoverage.State.failure(error) == expected)
        }
        let fields: [String: Any] = ["hostId": UUID().uuidString, "state": "unavailable"]
        #expect(try JSONDecoder().decode(ClusterCoverage.self, from: JSONSerialization.data(withJSONObject: fields)).state == .unavailable)
    }

    private func intent(host: UUID, parent: UUID, state: String) -> [String: Any] {
        ["id": "job", "jobId": "job", "ownerHostId": host.uuidString, "ownerThreadId": "parent",
         "kind": "remote_intent", "intentState": state, "provider": "codex", "source": "remote_intent",
         "title": "Child", "state": "unknown", "lastActiveAt": 1_793_181_600,
         "parent": ["hostId": parent.uuidString, "threadId": "parent"],
         "capabilities": ["inspect": false, "openConversation": false, "message": false,
                          "continueWork": false, "stop": false, "askParent": false]]
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
