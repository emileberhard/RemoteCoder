import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationAgentRosterTests {
    private func agent(_ id: String, parent: String? = nil, state: String, activeAt: Int64?) throws -> ConversationAgent {
        var fields: [String: Any] = ["id": id, "ownerThreadId": "root", "threadId": id, "title": id, "state": state,
            "capabilities": ["openConversation": true, "stop": false]]
        fields["parentId"] = parent
        fields["lastActiveAt"] = activeAt
        return try JSONDecoder().decode(ConversationAgent.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func splitsDirectChildrenIntoActiveAndDoneNewestFirst() throws {
        let roster = ConversationAgentRoster(agents: [
            try agent("old-done", state: "completed", activeAt: 10),
            try agent("waiting", state: "waiting", activeAt: 20),
            try agent("unknown-time", state: "unknown", activeAt: nil),
            try agent("failed", state: "failed", activeAt: 40),
            try agent("working", state: "working", activeAt: 30),
            try agent("stopped", state: "interrupted", activeAt: 40),
            try agent("removed", state: "removed", activeAt: 50),
        ])
        #expect(roster.active.map(\.id) == ["working", "waiting", "unknown-time"])
        #expect(roster.done.map(\.id) == ["failed", "stopped", "old-done"])
        #expect(roster.count == 6 && roster.isWorking)
    }

    @Test func descendantsStayInTheirOwnParentsRoster() throws {
        let roster = ConversationAgentRoster(agents: [
            try agent("child", state: "working", activeAt: 2),
            try agent("grandchild", parent: "child", state: "working", activeAt: 3),
            try agent("orphan", parent: "unlisted", state: "completed", activeAt: 1),
            try agent("cycle", parent: "cycle", state: "completed", activeAt: 0),
        ])
        #expect(roster.active.map(\.id) == ["child"])
        #expect(roster.done.map(\.id) == ["orphan", "cycle"])
    }
}
