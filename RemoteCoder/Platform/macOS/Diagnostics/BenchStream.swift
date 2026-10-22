#if RC_PERF_HARNESS
import Foundation

struct BenchStream: Sendable {
    private let plan: BenchStreamPlan
    private let session: ConversationSession
    private let address: ServerNotification.TurnAddress
    private let itemID: String
    private let chunks: [String]

    @concurrent
    static func populateHorizontalOverflow(session: ConversationSession, threadID: String) async throws -> String {
        let address = ServerNotification.TurnAddress(threadID: threadID, turnID: "perf-overflow-\(UUID().uuidString)")
        let headings = Array(repeating: String(repeating: "W", count: 32), count: 16).joined(separator: " | ")
        let separator = Array(repeating: "---", count: 16).joined(separator: " | ")
        let values = Array(repeating: "Value", count: 16).joined(separator: " | ")
        let text = "```text\n" + String(repeating: "W", count: 2_048)
            + "\n```\n\n| \(headings) |\n| \(separator) |\n| \(values) |\n"
        try await session.preparePerfStream(threadID: threadID, turnID: address.turnID)
        let item = ServerNotification.ItemEvent(address: address,
            item: .agentMessage(id: "\(address.turnID)-reply", text: text), startedAtOrdinal: nil,
            startedAtMs: nil, completedAtMs: nil, encodedBytes: text.utf8.count)
        do {
            try await send("turn/started", .turnStarted(address), session: session, address: address)
            try await send("item/completed", .itemCompleted(item), session: session, address: address)
            try await send("turn/completed", .turnCompleted(.init(address: address, status: .completed,
                completedAt: nil, errorMessage: nil)), session: session, address: address)
        } catch {
            try? await send("turn/completed", .turnCompleted(.init(address: address, status: .interrupted,
                completedAt: nil, errorMessage: nil)), session: session, address: address)
            throw error
        }
        let snapshot = await session.snapshot()
        guard snapshot.threadID == threadID,
              let message = snapshot.messages.first(where: { $0.canonicalTurnID == address.turnID && $0.text == text }) else {
            throw FixtureFailure.missingOverflow
        }
        return ChatStreamItem.message(message).id
    }

    @concurrent
    static func populateColdTable(session: ConversationSession, threadID: String) async throws -> String {
        let address = ServerNotification.TurnAddress(threadID: threadID, turnID: "perf-stream-\(UUID().uuidString)")
        try await session.preparePerfStream(threadID: threadID, turnID: address.turnID)
        let headers = (1...8).map { "Column \($0) heading" }.joined(separator: " | ")
        let separator = Array(repeating: "---", count: 8).joined(separator: " | ")
        let rows = (1...24).map { row in
            "| " + (1...8).map { column in "Row \(row) value \(column)" }.joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        let table = "| \(headers) |\n| \(separator) |\n\(rows)\n"
        func send(_ server: ServerNotification, method: String) async throws {
            try await Self.send(method, server, session: session, address: address)
        }
        func reply(_ id: String, text: String) -> ServerNotification.ItemEvent {
            .init(address: address, item: .agentMessage(id: id, text: text), startedAtOrdinal: nil,
                  startedAtMs: nil, completedAtMs: nil, encodedBytes: text.utf8.count)
        }
        do {
            try await send(.turnStarted(address), method: "turn/started")
            try await send(.itemCompleted(reply("\(address.turnID)-table", text: table)), method: "item/completed")
            for index in 0..<40 {
                try Task.checkCancellation()
                let text = "Continue with short reply \(index)."
                let user = ServerNotification.ItemEvent(address: address,
                    item: .userMessage(id: "\(address.turnID)-steer-\(index)", content: [.text(text: text, textElements: [])]),
                    startedAtOrdinal: nil, startedAtMs: nil, completedAtMs: nil, encodedBytes: text.utf8.count)
                try await send(.itemCompleted(user), method: "item/completed")
                try await send(.itemCompleted(reply("\(address.turnID)-reply-\(index)",
                    text: "A short settled reply keeps the large table outside the retained viewport.")), method: "item/completed")
                try await Task.sleep(for: .milliseconds(30))
            }
            try await send(.turnCompleted(.init(address: address, status: .completed, completedAt: nil, errorMessage: nil)),
                           method: "turn/completed")
        } catch {
            try? await send(.turnCompleted(.init(address: address, status: .interrupted, completedAt: nil, errorMessage: nil)),
                            method: "turn/completed")
            throw error
        }
        let snapshot = await session.snapshot()
        guard snapshot.threadID == threadID,
              let message = snapshot.messages.first(where: { $0.canonicalTurnID == address.turnID && $0.text == table }) else {
            throw FixtureFailure.missingTable
        }
        return ChatStreamItem.message(message).id
    }

    private enum FixtureFailure: LocalizedError {
        case missingTable, missingOverflow

        var errorDescription: String? {
            switch self {
            case .missingTable: "Cold table fixture did not retain its canonical message."
            case .missingOverflow: "Horizontal overflow fixture did not retain its canonical message."
            }
        }
    }

    @concurrent
    static func prepare(plan: BenchStreamPlan, session: ConversationSession, threadID: String) async throws -> BenchStream {
        let turnID = "perf-stream-\(UUID().uuidString)"
        let (opening, repeated) = source(for: plan.kind)
        let prefix = Array(opening)
        let body = Array(repeated)
        let closing = plan.kind == .wideTableThenProse ? Array("\n\nThe table has settled.") : []
        let closingOffset = max(prefix.count, plan.tickCount / 2 * plan.charsPerTick)
        var offset = 0
        let chunks = (0..<plan.tickCount).map { _ in
            String((0..<plan.charsPerTick).map { _ in
                defer { offset += 1 }
                if offset < prefix.count { return prefix[offset] }
                let position = offset - closingOffset
                if position >= 0, position < closing.count { return closing[position] }
                return body[(offset - prefix.count) % body.count]
            })
        }
        try Task.checkCancellation()
        try await session.preparePerfStream(threadID: threadID, turnID: turnID)
        return BenchStream(plan: plan, session: session,
            address: .init(threadID: threadID, turnID: turnID), itemID: "\(turnID)-reply", chunks: chunks)
    }

    @concurrent
    func rowID() async -> String? {
        let snapshot = await session.snapshot()
        let messages = snapshot.messages.filter { $0.canonicalTurnID == address.turnID && $0.role == .codex }
        guard snapshot.threadID == address.threadID, messages.count == 1, let message = messages.first else { return nil }
        return ChatStreamItem.message(message).id
    }

    @concurrent
    func run(started: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        var text = ""
        var itemID = self.itemID
        do {
            try await send("turn/started", .turnStarted(address))
            if plan.kind == .tableAppearance {
                let table = Self.source(for: .table)
                let text = table.0 + table.1
                let user = ServerNotification.ItemEvent(address: address,
                    item: .userMessage(id: "\(itemID)-table", content: [.text(text: text, textElements: [])]),
                    startedAtOrdinal: nil, startedAtMs: nil, completedAtMs: nil, encodedBytes: text.utf8.count)
                try await send("item/completed", .itemCompleted(user))
            }
            try await send("item/started", .itemStarted(item(id: itemID, text: "")))
            for (index, chunk) in chunks.enumerated() {
                try await Task.sleep(until: started + .milliseconds(index * plan.tickMs))
                try Task.checkCancellation()
                if plan.kind == .conversation, index == chunks.count / 2 {
                    try await send("item/completed", .itemCompleted(item(id: itemID, text: text)))
                    let user = ServerNotification.ItemEvent(address: address,
                        item: .userMessage(id: "\(self.itemID)-steer", content: [
                            .text(text: "Keep the next reply below this steered message.", textElements: [])]),
                        startedAtOrdinal: nil, startedAtMs: nil, completedAtMs: nil, encodedBytes: 64)
                    try await send("item/completed", .itemCompleted(user))
                    let completedAtMs = Int64(Date.now.timeIntervalSince1970 * 1000)
                    let reasoning = ServerNotification.ItemEvent(address: address,
                        item: .reasoning(id: "\(self.itemID)-reasoning", summary: ["Check row placement."], content: []),
                        startedAtOrdinal: nil, startedAtMs: Double(completedAtMs - 21_000),
                        completedAtMs: completedAtMs, encodedBytes: 64)
                    try await send("item/completed", .itemCompleted(reasoning))
                    itemID = "\(self.itemID)-continued"
                    text = ""
                    try await send("item/started", .itemStarted(item(id: itemID, text: "")))
                }
                PerfBuild.count("streamTicks")
                try await send("item/agentMessage/delta", .agentMessageDelta(.init(
                    address: address, itemID: itemID, delta: chunk, index: nil)))
                PerfBuild.count("streamDeltas")
                text += chunk
            }
            try await Task.sleep(until: started + .seconds(plan.seconds))
        } catch {
            try? await finish(itemID: itemID, text: text, status: .interrupted)
            throw error
        }
        try await finish(itemID: itemID, text: text, status: .completed)
    }

    private func finish(itemID: String, text: String, status: CodexAppServerV2.TurnStatus) async throws {
        try await send("item/completed", .itemCompleted(item(id: itemID, text: text)))
        try await send("turn/completed", .turnCompleted(.init(
            address: address, status: status, completedAt: nil, errorMessage: nil)))
    }

    private func item(id: String, text: String) -> ServerNotification.ItemEvent {
        .init(address: address, item: .agentMessage(id: id, text: text), startedAtOrdinal: nil,
              startedAtMs: nil, completedAtMs: nil, encodedBytes: text.utf8.count)
    }

    private func send(_ method: String, _ server: ServerNotification) async throws {
        try await Self.send(method, server, session: session, address: address)
    }

    private static func send(_ method: String, _ server: ServerNotification, session: ConversationSession,
                             address: ServerNotification.TurnAddress) async throws {
        let note = CodexGatewayNotification(method: method, params: nil, server: server, receivedAt: .now)
        let event = TurnScopedGatewayEvent(note: note, sequence: nil, method: method,
            threadID: address.threadID, turnID: address.turnID,
            normalizedTurnID: GatewayNotificationRouting.normalizeTurnID(address.turnID),
            jobID: GatewayNotificationRouting.jobID(threadID: address.threadID, turnID: address.turnID))
        try await session.ingestPerfStream(event)
    }

    private static func source(for kind: BenchStreamPlan.Kind) -> (String, String) {
        switch kind {
        case .mixed, .conversation:
            ("", passage)
        case .paragraph:
            ("", "A streaming reply keeps growing while the reader follows the latest words or scrolls through earlier turns. The same paragraph continues without a break so every update extends its text layout. ")
        case .code:
            ("```swift\nvar total = 0\n", "total += 1\nprint(total)\n")
        case .table:
            ("| Item | Value |\n| --- | --- |\n", "| Sample | 42 |\n")
        case .fitTable:
            ("| WWWWWWWWWWWWW | WWWWWWWWWWWWW | WWWWWWWWWWWWW | WWWWWWWWWWWWW |\n| --- | --- | --- | --- |\n| One | Two | Three | Four |\n", " ")
        case .tableAppearance:
            ("Narrow table\n\n" + source(for: .table).0 + source(for: .table).1
                + "\nWide table\n\n" + source(for: .wideTable).0
                + "\nNear-fit table\n\n" + source(for: .fitTable).0
                + "\nTable fixture settled.\n", " ")
        case .wideTable, .wideTableThenProse:
            ("| Column one wide heading | Column two wide heading | Column three wide heading | Column four wide heading | Column five wide heading | Column six wide heading | Column seven wide heading | Column eight wide heading |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n| One | Two | Three | Four | Five | Six | Seven | Eight |\n", " ")
        }
    }

    private static let passage = """
    ## Streaming transcript

    A reply grows while the reader follows the latest message or explores earlier turns. Each paragraph has stable wording so repeated runs exercise the same Markdown boundaries and line wrapping.

    The rendering worker prepares **formatted text**, preserves settled blocks, and publishes the changing tail. The transcript keeps its current reading position as the document grows.

    - Receive a small piece of assistant text.
    - Publish the next conversation snapshot at the normal cadence.
    - Render the latest paragraph and keep earlier content available.

    ```swift
    struct Sample {
        let index: Int
        let text: String
    }

    let samples = (0..<4).map { index in
        Sample(index: index, text: "Streaming reply")
    }
    for sample in samples {
        print(sample.index, sample.text)
    }
    ```

    This final paragraph closes one section. The next section repeats the same mixture of prose, list items, and code so a longer run remains deterministic.


    """
}
#endif
