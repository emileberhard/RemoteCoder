import Foundation
import Testing
@testable import RemoteCoderCore

struct PerformanceReplayVerificationTests: ConversationHistoryFixtures {
    @Test func boundedRetentionVerifiesInterleavedAssistantAndToolCompletions() throws {
        let history = history(items: [.agentMessage(id: "history", text: "Initial history")])
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history)
        var events: [PerformanceReplayScenario.Event] = []
        var items: [CodexAppServerV2.ThreadItem] = []
        for index in 0..<300 {
            let item: CodexAppServerV2.ThreadItem = index.isMultiple(of: 2)
                ? .agentMessage(id: "item-\(index)", text: "Answer \(index)")
                : .commandExecution(id: "item-\(index)", command: "true", cwd: "/tmp", status: .completed,
                    commandActions: [], aggregatedOutput: "Tool activity \(index)", exitCode: 0, durationMs: 1)
            items.append(item)
            let event = try event("item/completed", item: item, ordinal: index + 1)
            state.apply(event)
            events.append(.init(at: Double(index), frame: .object([
                "method": .string(event.method), "params": event.note.params ?? .null
            ])))
        }
        let snapshot = ConversationProjection.project(state)
        let completions = PerformanceReplayVerification.completions(threadID: "thread", events: events)
        var checks = PerformanceReplayVerification.checks(completions, messages: snapshot.messages, window: nil)
        #expect(completions.count == 150)
        #expect(checks.count == 100)
        #expect(checks[.init(turn: "turn", item: "item-0")] == nil)
        #expect(checks[.init(turn: "turn", item: "item-298")] == true)
        for offset in stride(from: 200, through: 0, by: -100) {
            let page = GatewayHistoryService.ConversationSnapshot.fixture(
                wire: entries(Array(items[offset..<min(offset + 100, items.count)]), turnID: "turn"),
                turns: [summary("turn")], older: offset == 0 ? nil : "before-\(offset)",
                placement: .reset)
            state.merge(page)
            let projected = ConversationProjection.project(state)
            for (identity, matches) in PerformanceReplayVerification.checks(completions, messages: projected.messages, window: page.window) {
                checks[identity] = (checks[identity] ?? true) && matches
            }
        }
        #expect(checks.count == completions.count)
        #expect(checks.values.allSatisfy { $0 })
        let latest = try #require(completions.first { $0.identity.item == "item-298" })
        let incorrect = ChatMessage(role: .codex, text: "Corrupted content", canonicalTurnID: "turn", canonicalItemID: "item-298")
        let loaded = GatewayHistoryService.ConversationSnapshot.fixture(wire: entries([items[298]], turnID: "turn"))
        #expect(PerformanceReplayVerification.checks([latest], messages: [incorrect], window: loaded.window)[latest.identity] == false)
        #expect(PerformanceReplayVerification.checks([latest], messages: [], window: loaded.window)[latest.identity] == false)
    }
}
