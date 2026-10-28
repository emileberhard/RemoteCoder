import Foundation
import Testing
@testable import RemoteCoder

actor HistoryGatewayFixture: CodexHistoryGateway, ConversationMarksRemote {
    enum HeldRead: Sendable { case header, classification, list, page }
    enum Failure: Error { case offline }
    struct History: Sendable {
        var entries: [CodexAppServerV2.ThreadItemsListResponse.Entry]
        var turns: [CodexAppServerV2.Turn]
    }

    let historyHostID = "history-fixture"
    let header: ConversationHeader
    private let wireHeader: CodexAppServerV2.Thread
    var pageReads = 0
    private(set) var itemPageLimits: [Int] = []
    private var rejectFirstItems: Bool?
    private var itemPagesExceedCapacity = false
    var requestedThreadIDs: [String] = []
    private(set) var headerReads: [String] = []
    private var history: History
    private var rejectedCursors: Set<String> = []
    private var completionTime: Int64? = 40
    private var holdSummary = false
    private var heldSummary: CheckedContinuation<Void, Never>?
    private var summaryArrival: CheckedContinuation<Void, Never>?
    private var codexHeaders: [CodexAppServerV2.Thread]?
    private var codexPageSizeCap = Int.max
    private var codexCompletionAvailable = false
    private var delegatedIDs: Set<String> = []
    private var classificationFails = false
    private var unknownAncestry: Set<String> = []
    private(set) var classificationRequests: [[String]] = []
    private(set) var listCursors: [String?] = []
    private(set) var claudeLimits: [Int] = []
    private(set) var claudeCursors: [String?] = []
    private var claudeHeaders: [CodexAppServerV2.Thread] = []
    private var claudePageSizeCap = 500
    private var shouldFail = false
    private var heldRead: HeldRead?
    private var readSuspension: CheckedContinuation<Void, Never>?
    private var readArrival: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var claudeListFails = false
    private(set) var marks = ConversationMarks(schemaVersion: 1, revision: 0, readBaseline: 1_000, threads: [:])
    private(set) var markUpdates: [[ConversationMarkChange]] = []
    private var marksFail = false
    private var holdMarksUpdate = false
    private var marksUpdateSuspension: CheckedContinuation<Void, Never>?
    private var marksUpdateArrival: CheckedContinuation<Void, Never>?

    init(threadID: String = "fixture") {
        wireHeader = .historyFixture(id: threadID, updatedAt: 10)
        header = ConversationHeader(wireHeader)
        history = HistoryServiceTests.workingHistory(turns: 20, ordinals: true)
    }

    static func header(id: String, updatedAt: Int64) -> ConversationHeader {
        .historyFixture(id: id, updatedAt: updatedAt)
    }

    func setHistory(_ history: History) { self.history = history }
    func appendToNewestTurn(_ count: Int) {
        guard let turnID = history.entries.last?.turnId else { return }
        for index in 0..<count {
            history.entries.append(.init(turnId: turnID, item: .agentMessage(id: "late-\(index)", text: "late \(index)"),
                startedAtOrdinal: Int64(history.entries.count), isComplete: true))
        }
    }
    func rejectCursor(_ cursor: String) { rejectedCursors.insert(cursor) }
    func setCompletionTime(_ timestamp: Int64?) { completionTime = timestamp }
    func holdNextSummaryRead() { holdSummary = true }
    func waitForSummaryRead() async {
        if heldSummary == nil { await withCheckedContinuation { summaryArrival = $0 } }
    }
    func releaseSummaryRead() { heldSummary?.resume(); heldSummary = nil }
    func failClassification() { classificationFails = true }
    func setCodexHeaders(_ threads: [CodexAppServerV2.Thread]) { codexHeaders = threads }
    func setCodexPageSizeCap(_ cap: Int) { codexPageSizeCap = cap }
    func setCodexCompletionAvailable() { codexCompletionAvailable = true }
    func setDelegatedIDs(_ ids: Set<String>) { delegatedIDs = ids }
    func setUnknownAncestry(_ ids: Set<String>) { unknownAncestry = ids }
    func setClaudeHeaders(_ threads: [CodexAppServerV2.Thread]) { claudeHeaders = threads }
    func setClaudePageSizeCap(_ cap: Int) { claudePageSizeCap = cap }
    func failClaudeList() { claudeListFails = true }
    func failPages(_ value: Bool) { shouldFail = value }
    func holdNextRead(_ kind: HeldRead) { heldRead = kind }
    func waitForHeldRead() async {
        if readSuspension == nil { _ = await withCheckedContinuation { readArrival = (UUID(), $0) } }
    }
    func waitForHeldRead(during task: Task<Void, Never>) async -> Bool {
        if readSuspension != nil { return true }
        let id = UUID()
        let completion = Task {
            await task.value
            if readArrival?.id == id { finishReadArrival(held: false) }
        }
        defer { completion.cancel() }
        return await withCheckedContinuation { readArrival = (id, $0) }
    }
    private func finishReadArrival(held: Bool) {
        let arrival = readArrival
        readArrival = nil
        arrival?.continuation.resume(returning: held)
    }
    func releaseHeldRead() { readSuspension?.resume(); readSuspension = nil; heldRead = nil }
    private func suspendRead(_ kind: HeldRead) async {
        guard heldRead == kind else { return }
        heldRead = nil
        await withCheckedContinuation { readSuspension = $0; finishReadArrival(held: true) }
    }
    func rejectFirstItemPage(typed: Bool) { rejectFirstItems = typed }
    func failItemPagesWithCapacity() { itemPagesExceedCapacity = true }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) async -> CodexAppServerV2.ThreadListResponse {
        listCursors.append(cursor)
        if let codexHeaders {
            let start = cursor.flatMap(Int.init) ?? 0
            let page = Array(codexHeaders.dropFirst(start).prefix(min(limit, codexPageSizeCap)))
            let next = start + page.count
            let captured = CodexAppServerV2.ThreadListResponse(data: page, nextCursor: next < codexHeaders.count ? String(next) : nil,
                completionTimes: Dictionary(uniqueKeysWithValues: page.map { ($0.id, codexCompletionAvailable ? Optional<Int64>.some(1) : nil) }))
            await suspendRead(.list)
            return captured
        }
        let captured = completionTime
        if holdSummary {
            holdSummary = false
            await withCheckedContinuation { heldSummary = $0; summaryArrival?.resume(); summaryArrival = nil }
        }
        return .init(data: [wireHeader], nextCursor: nil, completionTimes: shouldFail ? [:] : [wireHeader.id: captured])
    }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse {
        claudeLimits.append(limit)
        claudeCursors.append(cursor)
        if claudeListFails { throw Failure.offline }
        let start = cursor.flatMap(Int.init) ?? 0
        let page = Array(claudeHeaders.dropFirst(start).prefix(min(limit, claudePageSizeCap)))
        let next = start + page.count
        return .init(data: page, nextCursor: next < claudeHeaders.count ? String(next) : nil)
    }
    func readThread(threadID: String, includeTurns: Bool) async -> CodexAppServerV2.ThreadReadResponse {
        headerReads.append(threadID)
        let captured = claudeHeaders.first { $0.id == threadID } ?? codexHeaders?.first { $0.id == threadID } ?? wireHeader
        await suspendRead(.header)
        return .init(thread: captured)
    }
    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "conversation/agents/classify" {
            let ids = params.objectValue?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            classificationRequests.append(ids)
            if classificationFails { throw Failure.offline }
            await suspendRead(.classification)
            let relations = Dictionary(uniqueKeysWithValues: delegatedIDs.map { ($0, ["parentThreadId": "parent", "agentId": "launcher:\($0)"]) })
            return try JSONSerialization.data(withJSONObject: ["result": ["relations": relations,
                "knownRoots": ids.filter { !delegatedIDs.contains($0) && !unknownAncestry.contains($0) },
                "warnings": ids.contains(where: { unknownAncestry.contains($0) }) ? ["identityPending"] : []]])
        }
        pageReads += 1
        if shouldFail { throw Failure.offline }
        let fields = params.objectValue ?? [:]
        requestedThreadIDs.append(fields["threadId"]?.stringValue ?? "")
        await suspendRead(.page)
        if method == "thread/items/list" {
            if case .number(let limit)? = fields["limit"] { itemPageLimits.append(Int(limit)) }
            if itemPagesExceedCapacity {
                throw GatewayClient.ClientError.historyCapacity(actualBytes: 20_000_000, limitBytes: 16_000_000)
            }
            if let typed = rejectFirstItems {
                rejectFirstItems = nil
                if typed {
                    guard let failure = GatewayRPCFailure(code: -32003, message: "oversized", data: .object([
                        "kind": .string("historyPageTooLarge"), "retryable": .bool(false),
                        "actualBytes": .number(32_000_000), "limitBytes": .number(24_000_000)
                    ])) else { throw Failure.offline }
                    throw failure
                }
                throw GatewayClient.ClientError.serverError(message: "another -32003", code: -32003)
            }
        }
        if let cursor = fields["cursor"]?.stringValue, rejectedCursors.contains(cursor) {
            throw try #require(GatewayRPCFailure(code: -32600, message: "invalid cursor: \(cursor)", data: .object([
                "kind": .string("historyCursorInvalid"), "retryable": .bool(false)
            ])))
        }
        if method == "thread/items/list" {
            let page = Self.page(count: history.entries.count, fields: fields)
            return try JSONEncoder().encode(Reply(result: CodexAppServerV2.ThreadItemsListResponse(
                data: page.indices.map { history.entries[$0] }, nextCursor: page.next, backwardsCursor: page.backwards)))
        }
        let page = Self.page(count: history.turns.count, fields: fields)
        return try JSONEncoder().encode(Reply(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: page.indices.map { history.turns[$0] }, nextCursor: page.next, backwardsCursor: page.backwards)))
    }

    private static func page(count: Int, fields: [String: JSONValue]) -> (indices: [Int], next: String?, backwards: String?) {
        let step = fields["sortDirection"]?.stringValue == "asc" ? 1 : -1
        let limit: Int
        if case .number(let requested) = fields["limit"] { limit = Int(requested) } else { limit = 10 }
        let start = fields["cursor"]?.stringValue.flatMap(Int.init) ?? (step == 1 ? 0 : count - 1)
        let indices = (0..<limit).map { start + $0 * step }.filter { (0..<count).contains($0) }
        let next = indices.last.map { $0 + step }.flatMap { (0..<count).contains($0) ? String($0) : nil }
        return (indices, next, indices.first.map(String.init))
    }

    private struct Reply<T: Encodable>: Encodable { let id = UUID().uuidString; let result: T }
}

extension HistoryGatewayFixture {
    func failMarks(_ value: Bool) { marksFail = value }
    func holdNextMarksUpdate() { holdMarksUpdate = true }
    func waitForHeldMarksUpdate() async {
        if marksUpdateSuspension == nil { await withCheckedContinuation { marksUpdateArrival = $0 } }
    }
    func releaseHeldMarksUpdate() { marksUpdateSuspension?.resume(); marksUpdateSuspension = nil }

    func readConversationMarks() throws -> ConversationMarks {
        if marksFail { throw Failure.offline }
        return marks
    }

    func updateConversationMarks(_ changes: [ConversationMarkChange]) async throws -> ConversationMarks? {
        if holdMarksUpdate {
            holdMarksUpdate = false
            await withCheckedContinuation { marksUpdateSuspension = $0; marksUpdateArrival?.resume(); marksUpdateArrival = nil }
        }
        if marksFail { throw Failure.offline }
        markUpdates.append(changes)
        let before = marks
        var next = changes.reduce(marks) { $0.applying($1) }
        guard next != before else { return nil }
        next.revision = before.revision + 1
        for (id, entry) in next.threads where before.threads[id] != entry { next.threads[id]?.revision = next.revision }
        marks = next
        marks.threads = next.threads.filter { !$0.value.isEmpty }
        var delta = ConversationMarks(schemaVersion: next.schemaVersion, revision: next.revision, readBaseline: next.readBaseline,
                                      threads: [:])
        for id in Set(before.threads.keys).union(next.threads.keys) where before.threads[id] != next.threads[id] {
            delta.threads[id] = next.threads[id] ?? ThreadMarks(revision: next.revision)
        }
        return delta
    }

    func resolveProjects(directories: [String]) -> [ProjectIdentity] {
        directories.map { ProjectIdentity(cwd: $0, kind: .directory, key: $0, name: URL(filePath: $0).lastPathComponent, root: $0) }
    }
}
