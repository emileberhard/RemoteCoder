import Foundation
import Testing
@testable import RemoteCoder

struct TranscriptActivityRowTests {
    @Test func paginationPreservesExpandedActivityAcrossANewMessageBoundary() throws {
        let user = CodexAppServerV2.ThreadItem.userMessage(id: "u", content: [.text(text: "Import candidates", textElements: [])])
        let tail = [4848, 4820, 4809].map { ordinal in
            CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn", item: tool("cmd-\(ordinal)", status: .completed),
                startedAtOrdinal: Int64(ordinal), startedAtMs: 2000, completedAtMs: 3000, isComplete: true)
        }
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: tail, turns: [summary("turn")], older: "older"))
        state.activity(turnID: "turn", active: true)
        let original = try #require(ConversationProjection.project(state).timelines.last)
        state.toggleTimeline(original.id)
        let activityID = "activity-gw-thread-turn-cmd-4820"
        #expect(TranscriptRow.make(ConversationProjection.project(state).items).map(\.id).contains(activityID))

        let progress = CodexAppServerV2.ThreadItem.agentMessage(id: "progress", text: "Downloads complete")
        let update = GatewayHistoryService.ConversationSnapshot.fixture(wire: [
            .init(turnId: "turn", item: progress, startedAtOrdinal: 4801, startedAtMs: 1500, completedAtMs: 1600, isComplete: true),
            .init(turnId: "turn", item: user, startedAtOrdinal: 1, startedAtMs: 1000, completedAtMs: 1000, isComplete: true),
        ], placement: .older("older"), base: state.window)
        state.merge(update)
        let split = ConversationProjection.project(state)
        let section = try #require(split.timelines.first { $0.events.contains { $0.id == "gw-thread-turn-cmd-4820" } })
        #expect(section.id != original.id)
        #expect(section.isExpanded)
        #expect(TranscriptRow.make(split.items).map(\.id).contains(activityID))
        state.toggleTimeline(section.id)
        #expect(!ConversationProjection.project(state).timelines.contains { $0.isExpanded })
        state.merge(update)
        #expect(!ConversationProjection.project(state).timelines.contains { $0.isExpanded })
    }

    private func tool(_ id: String, status: CodexAppServerV2.CommandExecutionStatus) -> CodexAppServerV2.ThreadItem {
        .commandExecution(id: id, command: "sleep 1", cwd: "/tmp", status: status,
                          commandActions: [], aggregatedOutput: nil, exitCode: status == .completed ? 0 : nil, durationMs: nil)
    }

    private func summary(_ id: String, status: CodexAppServerV2.TurnStatus = .inProgress) -> CodexAppServerV2.Turn {
        CodexAppServerV2.Turn(id: id, items: [], startedAt: 1, completedAt: status == .inProgress ? nil : 2,
                              status: status, error: nil)
    }
}
