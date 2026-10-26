#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Foundation

struct PerformanceReplayScenario: Codable, Sendable {
    struct Conversation: Codable, Sendable {
        let thread: JSONValue
        let items: [JSONValue]
        let turns: [JSONValue]
        var itemFile: PerformanceReplayIndexedFile? = nil
        var turnFile: PerformanceReplayIndexedFile? = nil
        var localSubmission: LocalSubmission? = nil
        var itemCount: Int { itemFile.map { $0.offsets.count - 1 } ?? items.count }
        var turnCount: Int { turnFile.map { $0.offsets.count - 1 } ?? turns.count }
    }

    struct LocalSubmission: Codable, Sendable {
        let messageID: UUID
        let turnID: String
        let text: String
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
    var conversations: [Conversation]
    let events: [Event]
    let actions: [Action]
    let responses: [String: JSONValue]
    let errors: [String: JSONValue]?
    let httpResponses: [String: JSONValue]?
    let threadResponses: [String: [String: JSONValue]]?
    var completionTimes: [String: JSONValue]? = nil
    var captureSummary: JSONValue? = nil
    var fileTimeOffset: Double? = nil
    private static let secondKeys: Set<String> = ["createdAt", "updatedAt", "recencyAt", "lastActiveAt", "lastTurnCompletedAt",
        "startedAt", "completedAt", "observedAt", "resetsAt", "checkedAtUnixSeconds", "startedAtUnixSeconds",
        "readBaseline", "seenThrough", "doneThrough", "through", "sectionEnteredAt"]
    private static let millisecondKeys: Set<String> = ["startedAtMs", "completedAtMs"]

    enum Failure: Error, Equatable { case invalidScenario(String) }

    func validate() throws {
        guard (1...2).contains(version), capturedAt.isFinite, capturedAt > 0, !name.isEmpty, duration.isFinite, (10...900).contains(duration),
              (2...1024).contains(conversations.count), (1...20_000).contains(events.count),
              (1...60).contains(actions.count) else { throw Failure.invalidScenario("invalid bounds or version") }
        let ids = conversations.compactMap { $0.thread.objectValue?["id"]?.stringValue }
        guard ids.count == conversations.count, Set(ids).count == ids.count,
              conversations.allSatisfy({ $0.itemCount <= 20_000 && $0.turnCount <= 20_000 }) else {
            throw Failure.invalidScenario("invalid conversation identities or history size")
        }
        for conversation in conversations {
            try conversation.itemFile?.validate()
            try conversation.turnFile?.validate()
            if let submission = conversation.localSubmission {
                guard !submission.turnID.isEmpty, !submission.text.isEmpty, submission.text.utf8.count <= 1_048_576 else {
                    throw Failure.invalidScenario("invalid preparation submission")
                }
            }
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
        let offset = floor(now) - floor(capturedAt)
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
        guard var fields = Self.shift(value, by: offset).objectValue else { throw Failure.invalidScenario("fixture is not an object") }
        fields["capturedAt"] = .number(now)
        if let completionTimes {
            fields["completionTimes"] = .object(completionTimes.mapValues { Self.shift($0, by: offset, key: "completedAt") })
        }
        fields["fileTimeOffset"] = .number((fileTimeOffset ?? 0) + offset)
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }

    func prepared(to now: Double, root: URL, destination: URL) throws -> Self {
        try validate()
        guard root.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
            throw Failure.invalidScenario("prepared history must have a separate directory")
        }
        try FileManager.default.createDirectory(at: destination.appending(path: "history"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let originalBytes = conversations.reduce(UInt64(try JSONEncoder().encode(self).count)) { total, conversation in
            total + (conversation.itemFile?.offsets.last ?? 0) + (conversation.turnFile?.offsets.last ?? 0)
        }
        guard originalBytes <= 512 * 1_048_576 else { throw Failure.invalidScenario("fixture bundle exceeds 512 MiB") }
        var result = try rebased(to: now)
        var bytes: UInt64 = 0
        for index in result.conversations.indices {
            let original = conversations[index]
            if let file = original.itemFile {
                let prepared = try file.prepared(root: root, destination: destination,
                    path: "history/\(index)-items.jsonl", offset: result.fileTimeOffset ?? 0)
                result.conversations[index].itemFile = prepared
                bytes += prepared.offsets.last ?? 0
            }
            if let file = original.turnFile {
                let prepared = try file.prepared(root: root, destination: destination,
                    path: "history/\(index)-turns.jsonl", offset: result.fileTimeOffset ?? 0)
                result.conversations[index].turnFile = prepared
                bytes += prepared.offsets.last ?? 0
            }
            guard bytes <= 512 * 1_048_576 else { throw Failure.invalidScenario("prepared fixture exceeds 512 MiB") }
        }
        result.fileTimeOffset = 0
        guard bytes + UInt64(try JSONEncoder().encode(result).count) <= 512 * 1_048_576 else {
            throw Failure.invalidScenario("prepared fixture exceeds 512 MiB")
        }
        return result
    }

    static func shift(_ value: JSONValue, by offset: Double, key: String = "") -> JSONValue {
        switch value {
            case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, shift($0.value, by: offset, key: $0.key)) }))
            case .array(let values): return .array(values.map { shift($0, by: offset) })
            case .number(let number) where number > 0 && number < 4_000_000_000 && secondKeys.contains(key): return .number(number + offset)
            case .number(let number) where number > 0 && millisecondKeys.contains(key): return .number(number + offset * 1000)
            default: return value
        }
    }
}

enum PerformanceReplayResponse: Sendable {
    case value(JSONValue)
    case encoded(Data)

    func encoded() throws -> Data {
        let data: Data
        switch self {
        case .value(let value): data = try JSONEncoder().encode(value)
        case .encoded(let value): data = value
        }
        guard data.count <= 16 * 1_048_576 else {
            throw PerformanceReplayScenario.Failure.invalidScenario("response exceeds 16 MiB")
        }
        return data
    }
}

struct PerformanceReplayState: Sendable {
    private struct LiveItem: Sendable {
        var fields: [String: JSONValue]
        struct Delta: Sendable {
            let field: String
            let index: Int
            let text: String
        }
        var deltas: [Delta] = []

        func value() -> JSONValue {
            guard !deltas.isEmpty, var item = fields["item"]?.objectValue else { return .object(fields) }
            var text: [String] = [item["text"]?.stringValue ?? ""]
            var summary: [Int: [String]] = [:]
            var content: [Int: [String]] = [:]
            for delta in deltas {
                if delta.field == "summary" { summary[delta.index, default: []].append(delta.text) }
                else if delta.field == "content" { content[delta.index, default: []].append(delta.text) }
                else { text.append(delta.text) }
            }
            if text.count > 1 { item["text"] = .string(text.joined()) }
            for (key, additions) in [("summary", summary), ("content", content)] where !additions.isEmpty {
                var parts = item[key]?.arrayValue ?? []
                for (index, values) in additions {
                    while parts.count <= index { parts.append(.string("")) }
                    parts[index] = .string(([parts[index].stringValue ?? ""] + values).joined())
                }
                item[key] = .array(parts)
            }
            var result = fields
            result["item"] = .object(item)
            return .object(result)
        }
    }
    private var conversations: [PerformanceReplayScenario.Conversation]
    private let responses: [String: JSONValue]
    private let errors: [String: JSONValue]
    private let threadResponses: [String: [String: JSONValue]]
    private var marks: ConversationMarks?
    private var completionTimes: [String: JSONValue]
    private var liveItems: [String: [LiveItem]] = [:]
    private var liveTurns: [String: [JSONValue]] = [:]
    private var active: [String: JSONValue] = [:]
    private(set) var requests: [String: Int] = [:]
    private(set) var unsupported: [String: Int] = [:]
    private(set) var unsupportedRequests: [JSONValue] = []
    private var revision = 0
    private let startedAt: Double
    private let fixtureRoot: URL?
    private let fileTimeOffset: Double

    init(_ scenario: PerformanceReplayScenario, fixtureRoot: URL? = nil) throws {
        conversations = scenario.conversations
        startedAt = scenario.capturedAt
        self.fixtureRoot = fixtureRoot
        fileTimeOffset = scenario.fileTimeOffset ?? 0
        completionTimes = scenario.completionTimes ?? [:]
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
                    completionTimes[threadID] = completed
                    header["lastTurnCompletedAt"] = completed
                    header["updatedAt"] = completed
                    header["recencyAt"] = completed
                }
                header["status"] = .object(["type": .string(method == "turn/started" ? "active" : "idle"), "activeFlags": .array([])])
                let updated = PerformanceReplayScenario.Conversation(thread: .object(header), items: conversation.items, turns: conversation.turns,
                    itemFile: conversation.itemFile, turnFile: conversation.turnFile, localSubmission: conversation.localSubmission)
                conversations[index] = updated
            }
        }
        if method == "item/started" || method == "item/completed", let item = params["item"],
           let itemID = item.objectValue?["id"]?.stringValue {
            var entry: [String: JSONValue] = ["turnId": params["turnId"] ?? .null, "item": item,
                "isComplete": .bool(method == "item/completed")]
            let index = liveItems[threadID]?.firstIndex { $0.fields["item"]?.objectValue?["id"]?.stringValue == itemID }
            for key in ["startedAtOrdinal", "startedAtMs", "completedAtMs"] {
                entry[key] = params[key] ?? index.flatMap { liveItems[threadID]?[$0].fields[key] }
            }
            if let index { liveItems[threadID]?[index] = LiveItem(fields: entry) }
            else { liveItems[threadID, default: []].append(LiveItem(fields: entry)) }
        } else if ["item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta"].contains(method),
                  let itemID = params["itemId"]?.stringValue, params["delta"]?.stringValue != nil,
                  let index = liveItems[threadID]?.firstIndex(where: { $0.fields["item"]?.objectValue?["id"]?.stringValue == itemID }) {
            let value = params["delta"]?.stringValue ?? ""
            if method == "item/agentMessage/delta" {
                liveItems[threadID]?[index].deltas.append(.init(field: "text", index: 0, text: value))
            } else {
                let summary = method == "item/reasoning/summaryTextDelta"
                guard case .number(let rawIndex) = params[summary ? "summaryIndex" : "contentIndex"],
                      let part = Int(exactly: rawIndex), (0..<1000).contains(part) else { return }
                liveItems[threadID]?[index].deltas.append(.init(field: summary ? "summary" : "content", index: part, text: value))
            }
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

    mutating func response(to request: JSONValue) throws -> PerformanceReplayResponse? {
        guard let fields = request.objectValue, let id = fields["id"], let method = fields["method"]?.stringValue else { return nil }
        requests[method, default: 0] += 1
        let params = fields["params"]?.objectValue ?? [:]
        let threadID = params["threadId"]?.stringValue ?? ""
        let conversation = conversations.first { $0.thread.objectValue?["id"]?.stringValue == threadID }
        if var reply = threadResponses[threadID]?[method]?.objectValue {
            reply["id"] = id
            return .value(.object(reply))
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
            let headers = conversations.map(\.thread).filter {
                ($0.objectValue?["id"]?.stringValue?.hasPrefix("claude_") == true) == claude
            }.sorted {
                func updated(_ header: JSONValue) -> Double {
                    if case .number(let value) = header.objectValue?["updatedAt"] { return value }
                    return 0
                }
                if updated($0) != updated($1) { return updated($0) > updated($1) }
                return ($0.objectValue?["id"]?.stringValue ?? "") < ($1.objectValue?["id"]?.stringValue ?? "")
            }
            let rawCursor = params["cursor"]?.stringValue
            let offset = rawCursor.flatMap(Int.init) ?? 0
            let requested: Double
            if case .number(let value) = params["limit"] { requested = value } else { requested = 50 }
            guard (rawCursor == nil || Int(rawCursor ?? "") != nil), (0...headers.count).contains(offset),
                  let limit = Int(exactly: requested), (1...1000).contains(limit) else {
                throw PerformanceReplayScenario.Failure.invalidScenario("invalid list cursor or limit")
            }
            let end = min(headers.count, offset + limit)
            let page = Array(headers[offset..<end])
            let completions = page.compactMap { header -> (String, JSONValue)? in
                guard let id = header.objectValue?["id"]?.stringValue,
                      let value = completionTimes[id] else { return nil }
                return (id, value)
            }
            result = .object(["data": .array(page), "nextCursor": end < headers.count ? .string(String(end)) : .null,
                "completionTimes": .object(Dictionary(uniqueKeysWithValues: completions))])
        case "thread/read", "thread/resume":
            result = conversation.map { .object(["thread": $0.thread,
                "modelProvider": .string(threadID.hasPrefix("claude_") ? "claude" : "openai")]) }
        case "thread/subscribe":
            result = conversation.map { conversation in
                let itemCount = conversation.itemCount + liveItems[threadID, default: []].count
                let turnCount = conversation.turnCount + liveTurns[threadID, default: []].count
                let activeTurn = liveTurns[threadID]?.last { $0.objectValue?["status"] == .string("inProgress") }
                return .object(["status": .string("subscribed"), "subscriptionId": .string("replay-\(threadID)"),
                    "thread": conversation.thread, "checkpoint": .object([
                        "turnsBackwardsCursor": .string(String(turnCount)),
                        "itemsBackwardsCursor": .string(String(itemCount)),
                        "activeTurn": activeTurn ?? .null, "historyUnavailable": .bool(false),
                        "liveItems": .array(liveItems[threadID, default: []].map { $0.value() })])])
            }
        case "thread/items/list", "thread/turns/list":
            if let conversation {
                let isItems = method == "thread/items/list"
                let storedCount = isItems ? conversation.itemCount : conversation.turnCount
                let liveCount = isItems ? liveItems[threadID, default: []].count : liveTurns[threadID, default: []].count
                let count = storedCount + liveCount
                let ascending = params["sortDirection"]?.stringValue == "asc"
                let anchor = params["cursor"]?.stringValue.flatMap(Int.init)
                guard anchor.map({ (0...count).contains($0) }) ?? true else {
                    throw PerformanceReplayScenario.Failure.invalidScenario("invalid history cursor")
                }
                let requested: Double
                if case .number(let count) = params["limit"] { requested = count } else { requested = 50 }
                guard requested.isFinite, let requestedLimit = Int(exactly: requested) else { throw PerformanceReplayScenario.Failure.invalidScenario("invalid page limit") }
                let limit = min(100, max(1, requestedLimit))
                let first = ascending ? max(0, (anchor ?? -1) + 1) : min(count - 1, (anchor ?? count) - 1)
                var indices = ascending ? Array((min(count, first)..<min(count, first + limit)))
                    : (first < 0 ? [] : Array(stride(from: first, through: max(0, first - limit + 1), by: -1)))
                if let file = isItems ? conversation.itemFile : conversation.turnFile {
                    while let lower = indices.filter({ $0 < storedCount }).min(), let upper = indices.filter({ $0 < storedCount }).max(),
                          file.offsets[upper + 1] - file.offsets[lower] > 15 * 1_048_576 {
                        guard indices.count > 1 else { throw PerformanceReplayScenario.Failure.invalidScenario("single history item exceeds frame capacity") }
                        indices.removeLast()
                    }
                }
                let storedIndices = indices.filter { $0 < storedCount }
                let file = isItems ? conversation.itemFile : conversation.turnFile
                let stored: [Data]
                if let file, let lower = storedIndices.min(), let upper = storedIndices.max() {
                    guard let fixtureRoot, fileTimeOffset == 0 else {
                        throw PerformanceReplayScenario.Failure.invalidScenario("indexed history must be prepared before replay")
                    }
                    stored = try file.records(lower..<(upper + 1), root: fixtureRoot)
                } else { stored = [] }
                let storedStart = storedIndices.min() ?? 0
                var records: [Data] = []
                for index in indices {
                    if index < storedCount, file != nil { records.append(stored[index - storedStart]) }
                    else {
                        let value: JSONValue
                        if index < storedCount { value = (isItems ? conversation.items : conversation.turns)[index] }
                        else if isItems { value = liveItems[threadID, default: []][index - storedCount].value() }
                        else { value = liveTurns[threadID, default: []][index - storedCount] }
                        records.append(try JSONEncoder().encode(value))
                    }
                }
                while true {
                    let more = indices.last.map { ascending ? $0 + 1 < count : $0 > 0 } ?? false
                    let cursor: JSONValue = more ? indices.last.map { .string(String($0)) } ?? .null : .null
                    let backwards: JSONValue = indices.first.map { .string(String($0)) } ?? .null
                    var data = Data("{\"id\":".utf8)
                    data.append(try JSONEncoder().encode(id))
                    data.append(Data(",\"result\":{\"data\":[".utf8))
                    for (index, record) in records.enumerated() {
                        if index > 0 { data.append(44) }
                        data.append(record)
                    }
                    data.append(Data("],\"nextCursor\":".utf8))
                    data.append(try JSONEncoder().encode(cursor))
                    data.append(Data(",\"backwardsCursor\":".utf8))
                    data.append(try JSONEncoder().encode(backwards))
                    data.append(Data("}}".utf8))
                    if data.count <= 16 * 1_048_576 { return .encoded(data) }
                    guard records.count > 1 else { throw PerformanceReplayScenario.Failure.invalidScenario("single history item exceeds frame capacity") }
                    records.removeLast()
                    indices.removeLast()
                }
            } else { result = nil }
        case "daemon/activeTurns":
            result = activitySnapshot
        default: result = responses[method]
        }
        if let result { return .value(.object(["id": id, "result": result])) }
        if let error = errors[method] { return .value(.object(["id": id, "error": error])) }
        unsupported[method, default: 0] += 1
        if unsupportedRequests.count < 128 { unsupportedRequests.append(.object(["method": .string(method), "params": .object(params)])) }
        return .value(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Uncaptured replay RPC: \(method)")])]))
    }
}
#endif
