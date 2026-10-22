import Foundation
import Testing
@testable import RemoteCoderCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RC_LIVE_GATEWAY"] == "1"))
struct LiveConversationTitleTests {
    private static let prompt = "hey!! ok random request but could you first run `date` and then write me a tiny two-sentence story set on that weekday about a lighthouse keeper who adopts a seagull named Pickles? thanks so much"
    private static let slowPrompt = "please run `python3 -c 'import time; time.sleep(40)'` in the foreground of the shell first, then explain in two sentences why lighthouses are painted with stripes"

    @Test(.timeLimit(.minutes(4)), arguments: [(AgentProvider.codex, "gpt-6-luna"), (.claude, "sonnet")])
    func aCopiedPromptTitleIsReplacedThroughACachedSideQuestion(provider: AgentProvider, model: String) async throws {
        let gateway = try LocalGateway()
        let journal = gateway.journalFromNow()
        let client = GatewayClient(config: .init(url: gateway.url, authToken: gateway.token, hostLabel: "live gateway"), routes: nil)
        let notifications = await client.notifications()
        let cwd = FileManager.default.temporaryDirectory.path
        let thread = try await client.startOrResumeThread(threadID: nil, model: model, cwd: cwd, serviceTier: nil, provider: provider)
        _ = try await client.startTurn(threadID: thread.id, clientUserMessageID: UUID().uuidString, input: Self.prompt,
                                       model: model, cyberAccessProgram: nil, effort: "low", cwd: cwd, serviceTier: nil)

        let trace = try await journal.reviewTrace(of: thread.id, trigger: "turnCompleted")
        _ = try await client.updateConversationMarks([.setPurpose(threadID: thread.id, purpose: .probe)])
        let finished = trace["finished"]
        try #require(finished?["outcome"] == .string("renamed"), "title check ended \(String(describing: finished))")
        #expect(trace["decision"]?["shouldRename"] == .bool(true))
        let doneProbability = try #require(trace["decision"]?["doneProbability"]?.numberValue)
        let doneThreshold = try #require(trace["decision"]?["doneThreshold"]?.numberValue)
        #expect(trace["decision"]?["probablyDone"] == .bool(doneProbability >= doneThreshold))
        let written = try #require(trace["doneMarks"])
        #expect(written["changed"] == .bool(doneProbability >= doneThreshold))
        if doneProbability >= doneThreshold {
            let doneThrough = try #require(written["doneThrough"]?.numberValue)
            let marks = try await client.readConversationMarks()
            #expect(marks.threads[thread.id]?.doneThrough == Int64(doneThrough))
        }

        let name = try #require(trace["candidate"]?["proposedTitle"]?.stringValue)
        #expect(await Self.nameUpdate(of: thread.id, expectedDoneThrough: written["doneThrough"]?.numberValue.map { Int64($0) }, in: notifications) == name)
        let answer = try #require(trace["sideAnswer"])
        let cachedShare = provider == .codex
            ? try Self.codexCachedShare(answer["usage"])
            : try gateway.routerCachedShare(asked: try #require(trace["sideQuestion"]), answered: answer)
        print("\(provider.rawValue) \(thread.id): “\(name)”, cached input \(Int(cachedShare * 100))%")
        #expect(cachedShare >= 0.8)
        await client.retire()
    }

    @Test(.timeLimit(.minutes(4)), arguments: [(AgentProvider.codex, "gpt-6-luna"), (.claude, "sonnet")])
    func aNewConversationIsTitledMidTurnAndRegeneratedOnRequest(provider: AgentProvider, model: String) async throws {
        let gateway = try LocalGateway()
        let journal = gateway.journalFromNow()
        let client = GatewayClient(config: .init(url: gateway.url, authToken: gateway.token, hostLabel: "live gateway"), routes: nil)
        let notifications = await client.notifications()
        let cwd = FileManager.default.temporaryDirectory.path
        let thread = try await client.startOrResumeThread(threadID: nil, model: model, cwd: cwd, serviceTier: nil, provider: provider)
        _ = try await client.startTurn(threadID: thread.id, clientUserMessageID: UUID().uuidString, input: Self.slowPrompt,
                                       model: model, cyberAccessProgram: nil, effort: "low", cwd: cwd, serviceTier: nil)

        let early = try await journal.reviewTrace(of: thread.id, trigger: "earlyTitle")
        try #require(early["finished"]?["outcome"] == .string("renamed"), "early title ended \(String(describing: early["finished"]))")
        #expect(early["header"]?["turnStatus"] == .string("inProgress"))
        let earlyName = try #require(early["candidate"]?["proposedTitle"]?.stringValue)
        #expect(await Self.nameUpdate(of: thread.id, expectedDoneThrough: nil, in: notifications) == earlyName)

        try await client.regenerateTitle(threadID: thread.id)
        let requested = try await journal.reviewTrace(of: thread.id, trigger: "requested")
        _ = try await client.updateConversationMarks([.setPurpose(threadID: thread.id, purpose: .probe)])
        let regenerated = try #require(requested["candidate"]?["proposedTitle"]?.stringValue)
        #expect(regenerated != earlyName)
        #expect(await Self.nameUpdate(of: thread.id, expectedDoneThrough: nil, in: notifications) == regenerated)
        print("\(provider.rawValue) \(thread.id): early “\(earlyName)”, regenerated “\(regenerated)”")
        await client.retire()
    }

    private static func nameUpdate(of thread: String, expectedDoneThrough: Int64?, in notifications: AsyncStream<CodexGatewayNotification>) async -> String? {
        var name: String?
        var sawDone = expectedDoneThrough == nil
        for await notification in notifications {
            switch notification.server {
            case let .threadNameUpdated(update) where update.threadId == thread:
                name = update.threadName
            case let .conversationMarksChanged(delta):
                if let expectedDoneThrough, delta.threads[thread]?.doneThrough == expectedDoneThrough { sawDone = true }
            default: break
            }
            if sawDone, let name { return name }
        }
        return nil
    }

    private static func codexCachedShare(_ usage: JSONValue?) throws -> Double {
        let input = try #require(usage?["inputTokens"]?.numberValue)
        let cached = try #require(usage?["cachedInputTokens"]?.numberValue)
        return input > 0 ? cached / input : 0
    }
}

private struct LocalGateway {
    let url: URL
    let token: String
    let routerHost: String

    init() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".remote-coder/codex-gateway.env")
        var settings: [String: String] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { settings[String(pair[0])] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        let port = try #require(settings["RC_CODEX_GATEWAY_PORT"])
        url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        token = try #require(settings["RC_CODEX_GATEWAY_AUTH_TOKEN"])
        routerHost = try #require(settings["RC_CODEX_GATEWAY_ROUTER_URL"].flatMap { URL(string: $0)?.host() })
    }

    func journalFromNow() -> JournalTail {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/remote-coder/journal")
        let day = JournalTail.day(.now)
        let size = try? FileManager.default.attributesOfItem(atPath: JournalTail.file(day, in: directory).path)[.size] as? UInt64
        return JournalTail(directory: directory, day: day, offset: size ?? 0)
    }

    func routerCachedShare(asked: JSONValue, answered: JSONValue) throws -> Double {
        let start = try #require(time(asked["ts"])).addingTimeInterval(-2)
        let end = try #require(time(answered["ts"])).addingTimeInterval(2)
        let ssh = Process()
        ssh.executableURL = URL(filePath: "/usr/bin/ssh")
        ssh.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", routerHost,
                         "tail -n 5000 .local/share/llm-router/metadata.jsonl"]
        let output = Pipe()
        ssh.standardOutput = output
        try ssh.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ssh.waitUntilExit()
        let shares = jsonLines(data).filter { row in
            guard row["principal"] == .string("remotecoder"),
                  row["requested_model"]?.stringValue?.hasPrefix("claude-sonnet") == true,
                  let at = time(row["timestamp"]) else { return false }
            return start <= at && at <= end
        }.map { row in
            let usage = row["usage"]
            let read = usage?["cache_read_input_tokens"]?.numberValue ?? 0
            let total = read + (usage?["cache_creation_input_tokens"]?.numberValue ?? 0) + (usage?["input_tokens"]?.numberValue ?? 0)
            return total > 0 ? read / total : 0
        }
        return try #require(shares.max(), "no Sonnet request on \(routerHost) during the side question")
    }

    private func time(_ value: JSONValue?) -> Date? {
        value?.stringValue.flatMap { ISO8601DateFormatter().date(from: String($0.prefix(19)) + "Z") }
    }
}

private struct JournalTail {
    let directory: URL
    let day: String
    let offset: UInt64

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
    }

    static func file(_ day: String, in directory: URL) -> URL {
        directory.appending(path: "gateway-\(day).jsonl")
    }

    func reviewTrace(of thread: String, trigger: String) async throws -> [String: JSONValue] {
        while true {
            let records = self.records().filter {
                $0["kind"] == .string("review") && $0["threadId"] == .string(thread) && $0["trigger"] == .string(trigger)
            }
            let trace = Dictionary(records.compactMap { record in record["event"]?.stringValue.map { ($0, record) } },
                                   uniquingKeysWith: { _, last in last })
            if trace["finished"] != nil { return trace }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func records() -> [JSONValue] {
        let today = Self.day(.now)
        return read(day, from: offset) + (today == day ? [] : read(today, from: 0))
    }

    private func read(_ day: String, from offset: UInt64) -> [JSONValue] {
        guard let handle = try? FileHandle(forReadingFrom: Self.file(day, in: directory)) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return [] }
        return jsonLines(data)
    }
}

private func jsonLines(_ data: Data) -> [JSONValue] {
    data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { objectValue?[key] }

    var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }
}
