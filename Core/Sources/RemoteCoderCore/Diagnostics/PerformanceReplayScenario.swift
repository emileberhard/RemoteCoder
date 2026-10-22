#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Foundation

struct PerformanceReplayScenario: Codable, Sendable {
    struct Conversation: Codable, Sendable {
        let thread: JSONValue
        let items: [JSONValue]
        let turns: [JSONValue]
    }

    struct Event: Codable, Sendable {
        let at: Double
        let frame: JSONValue
    }

    struct Action: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case open, scroll, toggleSidebar }
        let at: Double
        let kind: Kind
        let threadID: String
        let message: Int?
    }

    let version: Int
    let capturedAt: Double
    let name: String
    let duration: Double
    let conversations: [Conversation]
    let events: [Event]
    let actions: [Action]
    let responses: [String: JSONValue]
    let errors: [String: JSONValue]?
    let httpResponses: [String: JSONValue]?
    let threadResponses: [String: [String: JSONValue]]?

    enum Failure: Error, Equatable { case invalidScenario(String) }

    func validate() throws {
        guard version == 1, capturedAt.isFinite, capturedAt > 0, !name.isEmpty, duration.isFinite, (10...120).contains(duration),
              (2...6).contains(conversations.count), (1...20_000).contains(events.count),
              (1...60).contains(actions.count) else { throw Failure.invalidScenario("invalid bounds or version") }
        let ids = conversations.compactMap { $0.thread.objectValue?["id"]?.stringValue }
        guard ids.count == conversations.count, Set(ids).count == ids.count,
              conversations.allSatisfy({ $0.items.count <= 1000 && $0.turns.count <= 500 }) else {
            throw Failure.invalidScenario("invalid conversation identities or history size")
        }
        for times in [events.map(\.at), actions.map(\.at)] {
            guard times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < duration }),
                  zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 }) else {
                throw Failure.invalidScenario("schedule must be finite, ordered and inside the window")
            }
        }
        guard actions.allSatisfy({ ids.contains($0.threadID) && ($0.kind == .scroll ? ($0.message ?? -1) >= 0 : $0.message == nil) }),
              events.allSatisfy({ event in
                  guard let fields = event.frame.objectValue, fields["method"]?.stringValue != nil,
                        let params = fields["params"]?.objectValue,
                        let thread = params["threadId"]?.stringValue else { return false }
                  return ids.contains(thread)
              }) else { throw Failure.invalidScenario("actions and events must address captured conversations") }
        var selected = ids[0]
        for action in actions {
            if action.kind == .open { selected = action.threadID }
            else if action.threadID != selected { throw Failure.invalidScenario("action addresses a conversation that is not selected") }
        }
    }

    func rebased(to now: Double) throws -> Self {
        let seconds: Set<String> = ["createdAt", "updatedAt", "recencyAt", "lastActiveAt", "lastTurnCompletedAt",
            "startedAt", "completedAt", "observedAt", "resetsAt", "checkedAtUnixSeconds", "startedAtUnixSeconds",
            "readBaseline", "seenThrough", "doneThrough", "through", "sectionEnteredAt"]
        let milliseconds: Set<String> = ["startedAtMs", "completedAtMs"]
        let offset = floor(now) - floor(capturedAt)
        func shift(_ value: JSONValue, key: String = "") -> JSONValue {
            switch value {
            case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, shift($0.value, key: $0.key)) }))
            case .array(let values): return .array(values.map { shift($0) })
            case .number(let number) where number > 0 && number < 4_000_000_000 && seconds.contains(key): return .number(number + offset)
            case .number(let number) where number > 0 && milliseconds.contains(key): return .number(number + offset * 1000)
            default: return value
            }
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
        guard var fields = shift(value).objectValue else { throw Failure.invalidScenario("fixture is not an object") }
        fields["capturedAt"] = .number(now)
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }
}

struct PerformanceReplayState: Sendable {
    private var conversations: [PerformanceReplayScenario.Conversation]
    private let responses: [String: JSONValue]
    private let errors: [String: JSONValue]
    private let threadResponses: [String: [String: JSONValue]]
    private var marks: ConversationMarks?
    private var liveItems: [String: [JSONValue]] = [:]
    private var liveTurns: [String: [JSONValue]] = [:]
    private var active: [String: JSONValue] = [:]
    private(set) var requests: [String: Int] = [:]
    private(set) var unsupported: [String: Int] = [:]
    private(set) var unsupportedRequests: [JSONValue] = []
    private var revision = 0
    private let startedAt: Double

    init(_ scenario: PerformanceReplayScenario) throws {
        conversations = scenario.conversations
        startedAt = scenario.capturedAt
        responses = scenario.responses
        errors = scenario.errors ?? [:]
        threadResponses = scenario.threadResponses ?? [:]
        marks = try responses["conversation/marks/read"].map { try JSONDecoder().decode(ConversationMarks.self, from: JSONEncoder().encode($0)) }
    }

    mutating func apply(_ frame: JSONValue) {
        guard let fields = frame.objectValue, let method = fields["method"]?.stringValue,
              let params = fields["params"]?.objectValue, let threadID = params["threadId"]?.stringValue else { return }
        revision += 1
        if method == "turn/started", let turn = params["turn"]?.objectValue {
            active[threadID] = .object(["threadId": .string(threadID), "turnId": turn["id"] ?? .null,
                "startedAtUnixSeconds": turn["startedAt"] ?? .number(startedAt), "promptPreview": .string("Replay"),
                "cwd": conversations.first { $0.thread.objectValue?["id"] == .string(threadID) }?.thread.objectValue?["cwd"] ?? .null])
        } else if method == "turn/completed" {
            active.removeValue(forKey: threadID)
        }
        if (method == "turn/started" || method == "turn/completed"), let value = params["turn"],
           let id = value.objectValue?["id"]?.stringValue {
            var turns = liveTurns[threadID, default: []]
            if let index = turns.firstIndex(where: { $0.objectValue?["id"]?.stringValue == id }) { turns[index] = value }
            else { turns.append(value) }
            liveTurns[threadID] = turns
            if let index = conversations.firstIndex(where: { $0.thread.objectValue?["id"] == .string(threadID) }),
               var header = conversations[index].thread.objectValue {
                let conversation = conversations[index]
                if method == "turn/completed", let completed = value.objectValue?["completedAt"] {
                    header["lastTurnCompletedAt"] = completed
                    header["updatedAt"] = completed
                    header["recencyAt"] = completed
                }
                header["status"] = .object(["type": .string(method == "turn/started" ? "active" : "idle"), "activeFlags": .array([])])
                conversations[index] = .init(thread: .object(header), items: conversation.items, turns: conversation.turns)
            }
        }
        if method == "item/started" || method == "item/completed", let item = params["item"],
           let itemID = item.objectValue?["id"]?.stringValue {
            var items = liveItems[threadID, default: []]
            let entry = JSONValue.object(["turnId": params["turnId"] ?? .null, "item": item,
                "isComplete": .bool(method == "item/completed")])
            if let index = items.firstIndex(where: { $0.objectValue?["item"]?.objectValue?["id"]?.stringValue == itemID }) {
                items[index] = entry
            } else { items.append(entry) }
            liveItems[threadID] = items
        } else if ["item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta"].contains(method), let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue, var items = liveItems[threadID],
                  let index = items.firstIndex(where: { $0.objectValue?["item"]?.objectValue?["id"]?.stringValue == itemID }),
                  var entry = items[index].objectValue, var item = entry["item"]?.objectValue {
            if method == "item/agentMessage/delta" {
                item["text"] = .string((item["text"]?.stringValue ?? "") + delta)
            } else {
                let summary = method == "item/reasoning/summaryTextDelta"
                let field = summary ? "summary" : "content"
                guard case .number(let rawIndex) = params[summary ? "summaryIndex" : "contentIndex"],
                      let part = Int(exactly: rawIndex), (0..<1000).contains(part) else { return }
                var parts = item[field]?.arrayValue ?? []
                while parts.count <= part { parts.append(.string("")) }
                parts[part] = .string((parts[part].stringValue ?? "") + delta)
                item[field] = .array(parts)
            }
            entry["item"] = .object(item)
            items[index] = .object(entry)
            liveItems[threadID] = items
        }
    }

    func notification(_ frame: JSONValue) -> JSONValue {
        guard var fields = frame.objectValue, fields["method"] == .string("daemon/activeTurns/changed") else { return frame }
        fields["params"] = activitySnapshot
        return .object(fields)
    }

    private var activitySnapshot: JSONValue {
        .object(["epoch": .string("performance-replay"), "revision": .number(Double(revision)),
            "activeTurns": .array(active.keys.sorted().compactMap { active[$0] }),
            "coverage": .object(["codex": .bool(true), "claude": .bool(true)]), "agentOwners": .object([:]),
            "externalActivity": .object(["sessions": .array([]), "claudeAvailable": .bool(true), "codexAvailable": .bool(true)])])
    }

    mutating func response(to request: JSONValue) throws -> JSONValue? {
        guard let fields = request.objectValue, let id = fields["id"], let method = fields["method"]?.stringValue else { return nil }
        requests[method, default: 0] += 1
        let params = fields["params"]?.objectValue ?? [:]
        let threadID = params["threadId"]?.stringValue ?? ""
        let conversation = conversations.first { $0.thread.objectValue?["id"]?.stringValue == threadID }
        if var reply = threadResponses[threadID]?[method]?.objectValue {
            reply["id"] = id
            return .object(reply)
        }
        let result: JSONValue?
        switch method {
        case "conversation/marks/read":
            result = try marks.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        case "conversation/marks/update":
            if var current = marks, let changes = params["changes"] {
                for change in try JSONDecoder().decode([ConversationMarkChange].self, from: JSONEncoder().encode(changes)) {
                    current = current.applying(change)
                }
                current.revision += 1
                for id in current.threads.keys { current.threads[id]?.revision = current.revision }
                marks = current
                result = .object(["delta": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(current))])
            } else { result = nil }
        case "conversation/questions/read":
            if var response = responses[method]?.objectValue, let queries = params["queries"]?.arrayValue {
                let ids = Set(queries.compactMap { $0.objectValue?["threadId"]?.stringValue })
                response["threads"] = .array(response["threads"]?.arrayValue?.filter { ids.contains($0.objectValue?["threadId"]?.stringValue ?? "") } ?? [])
                result = .object(response)
            } else { result = nil }
        case "initialize", "device/tools/declare", "conversation/subscriptions/set", "thread/subscription/close":
            result = .object([:])
        case "thread/list", "claude/thread/list":
            let claude = method == "claude/thread/list"
            result = .object(["data": .array(conversations.map(\.thread).filter {
                ($0.objectValue?["id"]?.stringValue?.hasPrefix("claude_") == true) == claude
            }), "nextCursor": .null])
        case "thread/read", "thread/resume":
            result = conversation.map { .object(["thread": $0.thread,
                "modelProvider": .string(threadID.hasPrefix("claude_") ? "claude" : "openai")]) }
        case "thread/subscribe":
            result = conversation.map { conversation in
                let items = conversation.items + liveItems[threadID, default: []]
                let turns = conversation.turns + liveTurns[threadID, default: []]
                let activeTurn = liveTurns[threadID]?.last { $0.objectValue?["status"] == .string("inProgress") }
                return .object(["status": .string("subscribed"), "subscriptionId": .string("replay-\(threadID)"),
                    "thread": conversation.thread, "checkpoint": .object([
                        "turnsBackwardsCursor": .string(String(turns.count)),
                        "itemsBackwardsCursor": .string(String(items.count)),
                        "activeTurn": activeTurn ?? .null, "historyUnavailable": .bool(false),
                        "liveItems": .array(liveItems[threadID, default: []])])])
            }
        case "thread/items/list", "thread/turns/list":
            if let conversation {
                let values = method == "thread/items/list" ? conversation.items + liveItems[threadID, default: []] : conversation.turns + liveTurns[threadID, default: []]
                let ascending = params["sortDirection"]?.stringValue == "asc"
                let indexed = Array(values.enumerated())
                let ordered = ascending ? indexed : Array(indexed.reversed())
                let anchor = params["cursor"]?.stringValue.flatMap(Int.init)
                let remaining = ordered.filter { entry in anchor.map { ascending ? entry.offset > $0 : entry.offset < $0 } ?? true }
                let requested: Double
                if case .number(let count) = params["limit"] { requested = count } else { requested = 50 }
                let limit = min(100, max(1, Int(requested)))
                let page = Array(remaining.prefix(limit))
                result = .object(["data": .array(page.map(\.element)),
                    "nextCursor": remaining.count > page.count ? page.last.map { .string(String($0.offset)) } ?? .null : .null,
                    "backwardsCursor": page.first.map { .string(String($0.offset)) } ?? .null])
            } else { result = nil }
        case "daemon/activeTurns":
            result = activitySnapshot
        default: result = responses[method]
        }
        if let result { return .object(["id": id, "result": result]) }
        if let error = errors[method] { return .object(["id": id, "error": error]) }
        unsupported[method, default: 0] += 1
        if unsupportedRequests.count < 128 { unsupportedRequests.append(.object(["method": .string(method), "params": .object(params)])) }
        return .object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Uncaptured replay RPC: \(method)")])])
    }
}
#endif
