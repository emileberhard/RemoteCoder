import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationAgentSectionsTests {
    private let cutoff: Int64 = 1_790_000_000

    private func agent(_ id: String, parent: String? = nil, state: String, activeAt: Int64?) throws -> ConversationAgent {
        var fields: [String: Any] = ["id": id, "ownerThreadId": "root", "provider": "claude", "source": "native",
            "title": id, "state": state, "capabilities": ["inspect": true, "openConversation": false, "message": false,
                "continueWork": false, "stop": false, "askParent": true]]
        fields["parentId"] = parent
        fields["lastActiveAt"] = activeAt
        return try JSONDecoder().decode(ConversationAgent.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func runningWorkAndActivityInsideTheWindowAreRecent() throws {
        let sections = ConversationAgentSections(agents: [
            try agent("running-for-days", state: "working", activeAt: cutoff - 3 * 86_400),
            try agent("waiting-unknown-time", state: "waiting", activeAt: nil),
            try agent("finished-just-inside", state: "completed", activeAt: cutoff),
            try agent("failed-inside", state: "failed", activeAt: cutoff + 60),
            try agent("finished-just-outside", state: "completed", activeAt: cutoff - 1),
            try agent("unknown-time", state: "unknown", activeAt: nil),
            try agent("stopped-outside", state: "interrupted", activeAt: cutoff - 86_400),
        ], activeSince: cutoff)
        #expect(sections.recent.map(\.id) == ["running-for-days", "waiting-unknown-time", "finished-just-inside", "failed-inside"])
        #expect(sections.earlier.map(\.id) == ["finished-just-outside", "unknown-time", "stopped-outside"])
    }

    @Test func recentWorkKeepsItsAncestorsAndOlderChildrenMoveToEarlier() throws {
        let sections = ConversationAgentSections(agents: [
            try agent("recent-child", parent: "old-parent", state: "completed", activeAt: cutoff + 10),
            try agent("old-parent", state: "completed", activeAt: cutoff - 86_400),
            try agent("running-parent", state: "working", activeAt: cutoff + 10),
            try agent("old-child", parent: "running-parent", state: "completed", activeAt: cutoff - 86_400),
            try agent("cycle", parent: "cycle", state: "unknown", activeAt: nil),
        ], activeSince: cutoff)
        #expect(sections.recent.map(\.id) == ["old-parent", "recent-child", "running-parent"])
        #expect(sections.recent.map(\.depth) == [0, 1, 0])
        #expect(sections.earlier.map(\.id) == ["old-child", "cycle"])
        #expect(sections.earlier.map(\.depth) == [0, 0])
    }

    @Test func longRunningAutomationCollapsesToItsLatestBurst() throws {
        let agents = try (0..<33).map { index in
            try agent("agent-\(index)", state: "unknown", activeAt: index < 29 ? cutoff - Int64(index + 1) * 3_600 : cutoff + Int64(index))
        }
        let sections = ConversationAgentSections(agents: agents, activeSince: cutoff)
        #expect(sections.recent.count == 4)
        #expect(sections.earlier.count == 29)
    }
}
