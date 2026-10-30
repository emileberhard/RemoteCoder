import Foundation
import Network
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct DeviceToolHostTests {
    @Test(arguments: [false, true])
    func contentSubscriptionsPrecedeReadsTrackLatestIntentAndRestoreOnReconnect(selected: Bool) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        await fixture.holdContentSubscriptionReplies()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: gateway, storage: temporary.storage)
        if selected { _ = await sessions.session(threadID: "claude_a") }
        do {
            let read = Task { try await gateway.historyPageData(method: "thread/items/list", params: .object(["threadId": .string("claude_b"), "limit": .number(10)])) }
            let initial = try #require(await fixture.requests.first { $0.method == "conversation/subscriptions/set" })
            #expect(initial.params == .object(["threadIds": .array(selected ? [.string("claude_a")] : [])]))
            #expect(await !gateway.isConnected)
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_b"], revision: 2)
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_a"], revision: 1)
            try await fixture.releaseContentSubscriptionReply()
            let updated = try #require(await fixture.requests.first { $0.method == "conversation/subscriptions/set" })
            #expect(updated.params == .object(["threadIds": .array([.string("claude_b")])]))
            #expect(await !fixture.recordedRequests.contains { $0.method == "thread/items/list" })
            try await fixture.releaseContentSubscriptionReply()
            try assertRecoveredHistory(try await read.value)
            await gateway.disconnect()
            let reconnect = Task { try await gateway.connectIfNeeded() }
            let restored = try #require(await fixture.requests.first { $0.method == "conversation/subscriptions/set" })
            #expect(restored.params == updated.params)
            try await fixture.releaseContentSubscriptionReply()
            try await reconnect.value
            let restoredHistory = try await gateway.historyPageData(method: "thread/items/list",
                params: .object(["threadId": .string("claude_b"), "limit": .number(10)]))
            try assertRecoveredHistory(restoredHistory)
            let replay = try await gateway.replayThreadNotifications(afterSequence: 0, epoch: nil, threadID: "claude_b")
            #expect(replay.notifications.count == 1)
            #expect(replay.notifications[0].message == DeviceToolSocketFixture.completedMessage)
            await gateway.replaceContentSubscriptions(threadIDs: [], revision: 3)
            let emptyRead = Task { try await gateway.historyPageData(method: "thread/items/list", params: .object(["threadId": .string("claude_b"), "limit": .number(10)])) }
            let empty = try #require(await fixture.requests.first { $0.method == "conversation/subscriptions/set" })
            #expect(empty.params == .object(["threadIds": .array([])]))
            try await fixture.releaseContentSubscriptionReply()
            try assertRecoveredHistory(try await emptyRead.value)
            await gateway.replaceContentSubscriptions(threadIDs: Set((0..<65).map { "claude_\($0)" }), revision: 4)
            try assertRecoveredHistory(try await gateway.historyPageData(method: "thread/items/list",
                params: .object(["threadId": .string("claude_b"), "limit": .number(10)])))
            guard case .failed(.subscriptionCapacity(let actual, let limit)) = await gateway.contentSubscriptionState else {
                Issue.record("Overflow must retain an explicit failed subscription state")
                await gateway.retire()
                await fixture.stop()
                return
            }
            #expect(actual == 65 && limit == 64)
            #expect(await fixture.recordedRequests.filter { $0.method == "thread/items/list" }.count == 4)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/subscriptions/set" }.count == 4)
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_c"], revision: 5)
            let recoveredRead = Task { try await gateway.historyPageData(method: "thread/items/list", params: .object(["threadId": .string("claude_b"), "limit": .number(10)])) }
            let recovered = try #require(await fixture.requests.first { $0.method == "conversation/subscriptions/set" })
            #expect(recovered.params == .object(["threadIds": .array([.string("claude_c")])]))
            try await fixture.releaseContentSubscriptionReply()
            try assertRecoveredHistory(try await recoveredRead.value)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    private func assertRecoveredHistory(_ data: Data) throws {
        struct Response: Decodable { let result: CodexAppServerV2.ThreadItemsListResponse }
        let page = try JSONDecoder().decode(Response.self, from: data).result
        #expect(page.data.count == 1)
        let entry = try #require(page.data.first)
        #expect(entry.turnId == "turn-b")
        #expect(entry.item == .agentMessage(id: "answer-b", text: "Recovered answer"))
        #expect(entry.isComplete == true)
        #expect(page.nextCursor == nil)
    }

    @Test func delayedWakeBetweenProbesResetsGraceForADelayedPongAndASilentPeer() {
        let start = ContinuousClock.now
        var healthy = GatewayReceiveDeadline(now: start)
        healthy.recordWake(at: start.advanced(by: .seconds(2)))
        healthy.recordReceive(at: start.advanced(by: .milliseconds(2100)))
        healthy.recordWake(at: start.advanced(by: .seconds(3)))
        healthy.recordWake(at: start.advanced(by: .seconds(33)))
        healthy.recordWake(at: start.advanced(by: .seconds(34)))
        #expect(!healthy.hasExpired(at: start.advanced(by: .seconds(34))))
        var silent = healthy
        healthy.recordReceive(at: start.advanced(by: .milliseconds(34200)))
        for second in 35...40 {
            let now = start.advanced(by: .seconds(second))
            healthy.recordWake(at: now)
            silent.recordWake(at: now)
            #expect(!healthy.hasExpired(at: now))
            #expect(!silent.hasExpired(at: now))
        }
        let expiry = start.advanced(by: .seconds(41))
        healthy.recordWake(at: expiry)
        silent.recordWake(at: expiry)
        #expect(!healthy.hasExpired(at: expiry))
        #expect(silent.hasExpired(at: expiry))
    }

    @Test func largeFrameDeadlineUsesThePayloadFloorAndOnlyACompleteMessageEndsIt() throws {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        deadline.announceLargeFrame(bytes: 32_000, at: start)
        deadline.recordPong(at: start.advanced(by: .seconds(6)), processedAt: start.advanced(by: .seconds(6)))
        deadline.resume(at: start.advanced(by: .seconds(6)))
        deadline.recordWake(at: start.advanced(by: .milliseconds(7999)))
        #expect(!deadline.hasExpired(at: start.advanced(by: .milliseconds(7999))))
        #expect(deadline.hasExpired(at: start.advanced(by: .seconds(8))))
        deadline.recordReceive(at: start.advanced(by: .seconds(7)))
        #expect(!deadline.hasExpired(at: start.advanced(by: .milliseconds(14999))))
        #expect(deadline.hasExpired(at: start.advanced(by: .seconds(15))))
        for bytes in [-1, 16_384, 33_554_433] {
            let data = try JSONEncoder().encode(JSONValue.object(["method": .string("connection/largeFrame"),
                "params": .object(["bytes": .number(Double(bytes))])]))
            #expect(throws: DecodingError.self) {
                try GatewayFrameDecoder.decodeSynchronously(data, rawResponseIDs: [])
            }
        }
    }

    @Test(arguments: [DeviceToolSocketFixture.LargeTransfer.completes, .stalls, .stallsWithPongs])
    fileprivate func largeFrameTransferSurvivesTheNormalGraceAndAStallStillExpires(transfer: DeviceToolSocketFixture.LargeTransfer) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: transfer == .stallsWithPongs)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                  authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            try await gateway.connectIfNeeded()
            let response = Task {
                try await gateway.call(method: transfer == .completes ? "probe/largeFrameComplete" : "probe/largeFrameStall",
                    params: nil, timeout: .seconds(20))
            }
            try await Task.sleep(for: .seconds(5))
            #expect(await gateway.isConnected)
            if transfer == .completes {
                #expect(try await response.value == .object(["padding": .string(String(repeating: "x", count: 65_536))]))
                #expect(await gateway.isConnected)
            } else {
                #expect(await waitUntil(timeout: .seconds(10)) { await !gateway.isConnected })
                await #expect(throws: (any Error).self) { try await response.value }
            }
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func peerLivenessIsCheckedWithoutAnApplicationRequest(repliesToPings: Bool) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: repliesToPings)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                  authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            try await gateway.connectIfNeeded()
            #expect(await gateway.isConnected)
            if repliesToPings {
                try await Task.sleep(for: .seconds(4))
                #expect(await gateway.isConnected)
            } else {
                #expect(await waitUntil(timeout: .seconds(12)) { await !gateway.isConnected })
            }
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }
    @Test func delayedPongsAndBackgroundResumptionKeepAHealthyConnection() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false, pongDelay: .milliseconds(1200))
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                  authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            try await gateway.connectIfNeeded()
            try await Task.sleep(for: .seconds(5))
            #expect(await gateway.isConnected)
            await gateway.suspendLivenessChecks()
            try await Task.sleep(for: .seconds(5))
            #expect(await gateway.isConnected)
            await gateway.resumeLivenessChecks()
            try await Task.sleep(for: .seconds(5))
            #expect(await gateway.isConnected)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test func receiveProgressKeepsAPeerAliveAndSilentReactivationHasANewGrace() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                  authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            try await gateway.connectIfNeeded()
            for _ in 0..<6 {
                try await fixture.send(.notification(.init(method: "test/progress", params: .object([:]))))
                try await Task.sleep(for: .seconds(1))
                #expect(await gateway.isConnected)
            }
            await gateway.suspendLivenessChecks()
            try await Task.sleep(for: .seconds(5))
            #expect(await gateway.isConnected)
            await gateway.resumeLivenessChecks()
            try await Task.sleep(for: .seconds(2))
            #expect(await gateway.isConnected)
            #expect(await waitUntil(timeout: .seconds(10)) { await !gateway.isConnected })
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }
    @Test(arguments: [true, false])
    func receiveLoopProcessesFramesWhileDeviceToolIsRunning(cancel: Bool) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        let gate = ToolGate()
        let host = DeviceToolHost(tools: [ControlledTool(gate: gate)])
        let invoke = invocation("first")
        let uploadContext = context(invoke)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
        let gateway = GatewayClient(config: .init(url: url, authToken: "fixture", hostLabel: "Fixture"), routes: nil,
            deviceTools: .init(host: host, uploadHost: uploadContext.host, uploader: uploadContext.uploader))
        let notifications = await gateway.notifications()
        let nextFrame = Task { await notifications.first { $0.method == "test/frame" } }
        defer { nextFrame.cancel() }
        do {
            try await gateway.connectIfNeeded()
            let declared = await fixture.requests.first { $0.method == "device/tools/declare" }
            #expect(declared?.params == .object(["tools": .array([.object(["name": .string("take_photo"), "version": .number(1)])])]))
            try await fixture.send(.notification(.init(method: "device/tool/invoke", params: try gateway.encodeToJSONValue(invoke))))
            await gate.waitUntilStarted()
            try await fixture.send(.notification(.init(method: "test/frame", params: .object(["text": .string("still streaming")]))))
            #expect(try await gateway.call(method: "test/ping", params: nil, timeout: .seconds(3)) == .object([:]))
            #expect(await nextFrame.value?.params == .object(["text": .string("still streaming")]))
            if cancel {
                try await fixture.send(.notification(.init(method: "device/tool/cancel", params: .object(["operationId": .string("first")]))))
                await gate.waitUntilCancelled()
            }
            await gate.finish()
            let resultRequest = try #require(await fixture.requests.first { $0.method == "device/tool/result" })
            let resultParams = try #require(resultRequest.params)
            let result = try JSONDecoder().decode(DeviceToolResult.self, from: JSONEncoder().encode(resultParams))
            #expect(result.operationId == "first")
            #expect(result.outcome == (cancel ? .cancelled : .succeeded))
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gate.finish()
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test(arguments: [DeviceToolSocketFixture.DeclarationReply.rejected(-32601), .rejected(-32600), .rejected(-32000), .ignored])
    private func declarationErrorsAreNonFatalAndMacRedeclaresEmptyToolsOnReconnect(reply: DeviceToolSocketFixture.DeclarationReply) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: reply)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                  authToken: "fixture", hostLabel: "Fixture"), routes: nil,
                                    timeouts: .init(request: .seconds(2)))
        do {
            for _ in 0..<2 {
                try await gateway.connectIfNeeded()
                #expect(await gateway.isConnected)
                #expect(try await gateway.call(method: "test/ping", params: nil, timeout: .seconds(3)) == .object([:]))
                let declared = await fixture.requests.first { $0.method == "device/tools/declare" }
                #expect(declared?.params == .object(["tools": .array([])]))
                await gateway.disconnect()
            }
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test func unexpectedAuthRefreshIsIgnoredWithoutReplyOrNotification() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                  authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let notifications = await gateway.notifications()
        let methods = Task { () -> [String] in
            var seen: [String] = []
            for await notification in notifications {
                seen.append(notification.method)
                if notification.method == "test/afterRefresh" { return seen }
            }
            return seen
        }
        defer { methods.cancel() }
        do {
            try await gateway.connectIfNeeded()
            let refreshID = CodexAppServerV2.JSONRPC.RequestId.string("refresh-request")
            try await fixture.send(.request(.init(id: refreshID, method: "account/chatgptAuthTokens/refresh", params: .object([:]))))
            try await fixture.send(.notification(.init(method: "test/afterRefresh", params: nil)))
            #expect(await methods.value == ["daemon/ready", "test/afterRefresh"])
            #expect(try await gateway.call(method: "test/ping", params: nil, timeout: .seconds(3)) == .object([:]))
            #expect(await fixture.replyIDs.isEmpty)
            #expect(await gateway.isConnected)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test func slowToolDoesNotBlockAdmissionAndIsExclusiveAcrossConnections() async throws {
        let gate = ToolGate()
        let host = DeviceToolHost(tools: [ControlledTool(gate: gate)])
        let sink = ResultSink()
        let generation = UUID()
        let invoke = invocation("first")
        #expect(await host.invoke(invoke, generation: generation, context: context(invoke)) { await sink.receive($0) } == nil)
        await gate.waitUntilStarted()
        let second = invocation("second")
        let busy = await host.invoke(second, generation: UUID(), context: context(second)) { await sink.receive($0) }
        #expect(busy?.outcome == .refused)
        #expect(busy?.reason == .busy)
        #expect(await host.invoke(invoke, generation: generation, context: context(invoke)) { await sink.receive($0) } == nil)
        await gate.finish()
        let result = await sink.result()
        #expect(result.operationId == "first")
        #expect(result.outcome == .succeeded)
        #expect(result.content == [.image(mimeType: "image/jpeg", data: "/9j/")])
        #expect(await gate.starts == 1)
    }

    @Test(arguments: [true, false])
    func cancelsExactOperationAndKeepsBusyUntilCleanupFinishes(connectionLost: Bool) async {
        let gate = ToolGate()
        let host = DeviceToolHost(tools: [ControlledTool(gate: gate, failureOnFinish: true)])
        let sink = ResultSink()
        let generation = UUID()
        let invoke = invocation("first")
        _ = await host.invoke(invoke, generation: generation, context: context(invoke)) { await sink.receive($0) }
        await gate.waitUntilStarted()
        await host.cancel(.init(operationId: "another"), generation: generation)
        await host.cancel(.init(operationId: "first"), generation: UUID())
        await host.connectionLost(generation: UUID())
        if connectionLost { await host.connectionLost(generation: generation) }
        else { await host.cancel(.init(operationId: "first"), generation: generation) }
        await gate.waitUntilCancelled()
        let next = invocation("next")
        #expect(await host.invoke(next, generation: UUID(), context: context(next)) { await sink.receive($0) }?.reason == .busy)
        await gate.finish()
        #expect(await sink.result().outcome == .cancelled)
        #expect(await gate.cancellations == 1)
    }

    @Test(arguments: [true, false])
    func refusesExpiredOrUnsupportedInvocationBeforeToolStarts(expired: Bool) async {
        let gate = ToolGate()
        let host = DeviceToolHost(tools: [ControlledTool(gate: gate)])
        let invoke = DeviceToolInvoke(operationId: "first", tool: "take_photo", version: expired ? 1 : 2,
                                      arguments: .object([:]), deadlineUnixMs: expired ? 1 : futureDeadline)
        let result = await host.invoke(invoke, generation: UUID(), context: context(invoke)) { _ in Issue.record("Refusal should be immediate.") }
        #expect(result?.outcome == .refused)
        #expect(result?.reason == (expired ? .deadlinePassed : .invalidArguments))
        #expect(await gate.starts == 0)
    }

    @Test func emptyMacHostDoesNotExecuteTools() async {
        let host = DeviceToolHost(tools: [])
        let invoke = invocation("first")
        #expect(host.declarations.tools.isEmpty)
        #expect(await host.invoke(invoke, generation: UUID(), context: context(invoke)) { _ in }?.reason == .invalidArguments)
    }

    @Test(arguments: [DeviceToolOutcome.refused, .failed])
    func platformFailuresPreserveTypedOutcome(outcome: DeviceToolOutcome) async {
        let host = DeviceToolHost(tools: [FailingTool(outcome: outcome)])
        let sink = ResultSink()
        let invoke = invocation("first")
        _ = await host.invoke(invoke, generation: UUID(), context: context(invoke)) { await sink.receive($0) }
        let result = await sink.result()
        #expect(result.outcome == outcome)
        #expect(result.reason == (outcome == .refused ? .foregroundRequired : nil))
        #expect(result.detail == "capture unavailable")
    }

    private var futureDeadline: Int64 { Int64(Date.now.addingTimeInterval(60).timeIntervalSince1970 * 1_000) }

    private func invocation(_ id: String) -> DeviceToolInvoke {
        .init(operationId: id, tool: "take_photo", version: 1, arguments: .object([:]), deadlineUnixMs: futureDeadline)
    }

    private func context(_ invoke: DeviceToolInvoke) -> DeviceToolContext {
        .init(host: .init(id: UUID(), name: "Test", hostname: "localhost", port: 8787, authToken: "fixture", transport: .trustedNetwork),
              uploader: UnusedUploader(), deadlineUnixMs: invoke.deadlineUnixMs)
    }
}

private struct ControlledTool: DeviceTool {
    let gate: ToolGate
    var failureOnFinish = false
    var declaration: DeviceToolsDeclare.Tool { .init(name: "take_photo", version: 1) }
    func execute(arguments: JSONValue, context: DeviceToolContext) async throws -> DeviceToolOutput {
        await withTaskCancellationHandler {
            await gate.startAndWait()
        } onCancel: {
            Task { await gate.cancelled() }
        }
        if failureOnFinish { throw FailingTool.Failure() }
        return .init(content: [.image(mimeType: "image/jpeg", data: "/9j/")], originals: [], detail: nil)
    }
}

private struct FailingTool: DeviceTool {
    let outcome: DeviceToolOutcome
    var declaration: DeviceToolsDeclare.Tool { .init(name: "take_photo", version: 1) }
    struct Failure: LocalizedError { var errorDescription: String? { "capture unavailable" } }
    func execute(arguments: JSONValue, context: DeviceToolContext) async throws -> DeviceToolOutput {
        if outcome == .refused { throw DeviceToolRefusal(reason: .foregroundRequired, detail: "capture unavailable") }
        throw Failure()
    }
}

private actor ToolGate {
    private(set) var starts = 0
    private(set) var cancellations = 0
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var cancelledWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func startAndWait() async {
        starts += 1
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { finishWaiter = $0 }
    }
    func waitUntilStarted() async {
        if starts > 0 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func cancelled() {
        cancellations += 1
        cancelledWaiter?.resume()
        cancelledWaiter = nil
    }
    func waitUntilCancelled() async {
        if cancellations > 0 { return }
        await withCheckedContinuation { cancelledWaiter = $0 }
    }
    func finish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

private actor ResultSink {
    private var value: DeviceToolResult?
    private var waiter: CheckedContinuation<DeviceToolResult, Never>?
    func receive(_ value: DeviceToolResult) {
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }
    func result() async -> DeviceToolResult {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private struct UnusedUploader: GatewayFileUploading {
    func upload(_ upload: GatewayUpload, to host: GatewayHostConfiguration,
                progress: @escaping @Sendable (GatewayUploadProgress) -> Void) async throws -> UploadedFile {
        Issue.record("Core lifecycle tests should not upload.")
        throw CancellationError()
    }
}

actor DeviceToolSocketFixture {
    enum LargeTransfer: Sendable { case completes, stalls, stallsWithPongs }

    enum DeclarationReply: Sendable {
        case accepted, rejected(Int64), ignored
    }

    static let completedMessage = JSONValue.object(["method": .string("item/completed"),
        "params": .object(["threadId": .string("claude_b"), "turnId": .string("turn-b"),
            "item": .object(["id": .string("answer-b"), "type": .string("agentMessage"), "text": .string("Recovered answer")])])])
    static let historyResult = JSONValue.object(["data": .array([.object(["turnId": .string("turn-b"),
        "item": .object(["id": .string("answer-b"), "type": .string("agentMessage"), "text": .string("Recovered answer")]),
        "isComplete": .bool(true)])]), "nextCursor": .null, "backwardsCursor": .null])

    private let listener: NWListener
    private let queue = DispatchQueue(label: "DeviceToolSocketFixture")
    private let declarationReply: DeclarationReply
    private let pongDelay: Duration?
    private let answersPings: Bool
    private var withholdsReady = false
    private var closeBeforeReadyCode: NWProtocolWebSocket.CloseCode?
    private var initializeRejected = false
    private var cancelRequestCapability: Bool?
    private var providers: JSONValue?
    private var failures: [String: CodexAppServerV2.JSONRPC.ErrorObject] = [:]
    private(set) var recordedNotifications: [CodexAppServerV2.JSONRPC.Notification] = []
    private var heldMethods: Set<String> = []
    private var heldRequests: [(CodexAppServerV2.JSONRPC.Request, NWConnection)] = []
    private var results: [String: JSONValue] = [:]
    private var capacityFailures: [String: (remaining: Int, retryable: Bool)] = [:]
    private(set) var pingCount = 0
    private let pingStream = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(16))
    nonisolated var pings: AsyncStream<Int> { pingStream.stream }
    private var stopped = false
    private var connections: [NWConnection] = []
    private var stalledConnections: [NWConnection] = []
    private(set) var replyIDs: [CodexAppServerV2.JSONRPC.RequestId] = []
    private(set) var recordedRequests: [CodexAppServerV2.JSONRPC.Request] = []
    private var currentHistoryResult = DeviceToolSocketFixture.historyResult
    private var contentSubscriptionRejection: Int64?
    private(set) var acceptedConnections = 0
    private(set) var acknowledgedContentSubscriptions: Set<String>?
    private var contentSubscriptionRepliesHeld = false
    private var heldContentSubscriptionReplies: [(CodexAppServerV2.JSONRPC.RequestId, NWConnection)] = []
    private var ready: CheckedContinuation<UInt16, Error>?
    private let requestStream = AsyncStream<CodexAppServerV2.JSONRPC.Request>.makeStream(bufferingPolicy: .bufferingNewest(16))
    nonisolated var requests: AsyncStream<CodexAppServerV2.JSONRPC.Request> { requestStream.stream }
    private let notificationStream = AsyncStream<CodexAppServerV2.JSONRPC.Notification>.makeStream(bufferingPolicy: .bufferingNewest(16))
    nonisolated var notifications: AsyncStream<CodexAppServerV2.JSONRPC.Notification> { notificationStream.stream }

    init(declarationReply: DeclarationReply, repliesToPings: Bool = true, pongDelay: Duration? = nil) throws {
        self.declarationReply = declarationReply
        self.pongDelay = pongDelay
        answersPings = repliesToPings || pongDelay != nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = false
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            listener.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port else { return }
            ready?.resume(returning: port.rawValue)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        acceptedConnections += 1
        connections.removeAll { $0.state == .cancelled }
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection)
        if let closeBeforeReadyCode {
            close(connection, code: closeBeforeReadyCode)
            return
        }
        let sendsReady = !withholdsReady && (answersPings || acceptedConnections == 1)
        guard sendsReady else { return }
        var ready: [String: JSONValue] = ["notificationEpoch": .string("fixture"), "notificationSequence": .number(0)]
        if let cancelRequestCapability { ready["capabilities"] = .object(["cancelRequest": .bool(cancelRequestCapability)]) }
        if let providers { ready["providers"] = providers }
        let params = JSONValue.object(ready)
        Task { try? await send(.notification(.init(method: "daemon/ready", params: params)), on: connection) }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            if error != nil { connection.cancel(); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .ping {
                Task { await self?.receivedPing(data ?? Data(), on: connection) }
                return
            }
            if metadata?.opcode == .pong {
                Task { await self?.receive(connection) }
                return
            }
            guard metadata?.opcode != .close, let data else { connection.cancel(); return }
            guard metadata?.opcode == .text else {
                Issue.record("Gateway clients must send JSON-RPC as text frames")
                connection.cancel()
                return
            }
            Task { await self?.received(data, from: connection) }
        }
    }

    private func receivedPing(_ data: Data, on connection: NWConnection) {
        pingCount += 1
        pingStream.continuation.yield(pingCount)
        receive(connection)
        Task { await replyToPing(data, on: connection) }
    }

    private func replyToPing(_ data: Data, on connection: NWConnection) async {
        guard answersPings, answers(connection) else { return }
        if let pongDelay {
            do { try await Task.sleep(for: pongDelay) } catch { return }
        }
        guard answers(connection) else { return }
        let context = NWConnection.ContentContext(identifier: "pong", metadata: [NWProtocolWebSocket.Metadata(opcode: .pong)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func answers(_ connection: NWConnection) -> Bool {
        !stopped && !stalledConnections.contains { $0 === connection }
    }

    func stallExistingConnections() {
        stalledConnections.append(contentsOf: connections)
    }

    func withholdReady() {
        withholdsReady = true
    }

    func closeBeforeReady(code: NWProtocolWebSocket.CloseCode = .protocolCode(.internalServerError)) {
        closeBeforeReadyCode = code
    }

    func admitConnections() {
        closeBeforeReadyCode = nil
    }

    func closeConnections(code: NWProtocolWebSocket.CloseCode) {
        for connection in connections { close(connection, code: code) }
    }

    private func close(_ connection: NWConnection, code: NWProtocolWebSocket.CloseCode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func rejectInitialize() {
        initializeRejected = true
    }

    private func received(_ data: Data, from connection: NWConnection) async {
        guard !stopped, !stalledConnections.contains(where: { $0 === connection }) else { return }
        do {
            let frame = try JSONDecoder().decode(CodexAppServerV2.JSONRPC.Message.self, from: data)
            switch frame {
            case .notification(let notification):
                recordedNotifications.append(notification)
                notificationStream.continuation.yield(notification)
            case .response(let response): replyIDs.append(response.id)
            case .error(let response):
                replyIDs.append(response.id)
            default: break
            }
            if case .request(let request) = frame {
                if recordedRequests.count == 32 { recordedRequests.removeFirst() }
                recordedRequests.append(request)
                requestStream.continuation.yield(request)
                if heldMethods.contains(request.method) {
                    heldRequests.append((request, connection))
                    receive(connection)
                    return
                }
                if request.method == "conversation/subscriptions/set", contentSubscriptionRepliesHeld {
                    #expect(heldContentSubscriptionReplies.isEmpty)
                    heldContentSubscriptionReplies.append((request.id, connection))
                    receive(connection)
                    return
                }
                if request.method.hasPrefix("probe/largeFrame") {
                    try await sendLargeFrame(request, on: connection,
                        transfer: request.method == "probe/largeFrameComplete" ? .completes : .stalls)
                    receive(connection)
                    return
                }
                let response: CodexAppServerV2.JSONRPC.Message?
                if let failure = capacityFailures[request.method], failure.remaining > 0 {
                    capacityFailures[request.method]?.remaining -= 1
                    response = .error(.init(error: .init(code: -32001, data: .object([
                        "kind": .string("capacity"), "retryable": .bool(failure.retryable)]), message: "Capacity reached"), id: request.id))
                } else if let failure = failures[request.method] {
                    response = .error(.init(error: failure, id: request.id))
                } else if let value = results[request.method] {
                    response = .response(.init(id: request.id, result: value))
                } else if request.method == "conversation/subscriptions/set", let code = contentSubscriptionRejection {
                    response = .error(.init(error: .init(code: code,
                        data: code == -32001 ? .object(["kind": .string("capacity"), "retryable": .bool(false),
                            "limit": .number(64)]) : nil,
                        message: code == -32600 ? "unknown variant `conversation/subscriptions/set`" : "Subscription rejected"), id: request.id))
                } else if request.method == "initialize", initializeRejected {
                    response = .error(.init(error: .init(code: -32603, data: nil, message: "Initialize rejected"), id: request.id))
                } else if request.method == "device/tools/declare" {
                    switch declarationReply {
                    case .accepted: response = .response(.init(id: request.id, result: .object([:])))
                    case .rejected(let code): response = .error(.init(error: .init(code: code, data: nil, message: "Declaration rejected"), id: request.id))
                    case .ignored: response = nil
                    }
                } else {
                    let value: JSONValue
                    switch request.method {
                    case "thread/read":
                        value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(CodexAppServerV2.ThreadReadResponse(thread: .init(
                            id: request.params?.objectValue?["threadId"]?.stringValue ?? "claude_b", preview: "Recovered answer",
                            createdAt: 1, updatedAt: 2, path: nil, cwd: "/tmp", source: .string("cli"), status: .idle))))
                    case "thread/items/list": value = currentHistoryResult
                    case "daemon/replayNotifications":
                        value = .object(["generatedAtUnixSeconds": .number(1), "epoch": .string("fixture"),
                            "throughSequence": .number(1), "hasMore": .bool(false), "evictedBefore": .bool(false),
                            "skipped": .array([]), "notifications": .array([.object(["sequence": .number(1),
                                "timestampUnixSeconds": .number(1), "message": Self.completedMessage])])])
                    case "device/tool/result": value = .object(["accepted": .bool(true)])
                    default: value = .object([:])
                    }
                    if request.method == "conversation/subscriptions/set" {
                        acknowledgedContentSubscriptions = Set(request.params?.objectValue?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                    }
                    response = .response(.init(id: request.id, result: value))
                }
                if let response { try await send(response, on: connection) }
            }
            receive(connection)
        } catch {
            if !stopped, !Self.isPeerDisconnect(error) { Issue.record(error) }
            connection.cancel()
            requestStream.continuation.finish()
        }
    }

    private static func isPeerDisconnect(_ error: Error) -> Bool {
        guard case .posix(let code) = error as? NWError else { return false }
        return [.ENOTCONN, .ECONNRESET, .EPIPE, .ECANCELED].contains(code)
    }

    func send(_ message: CodexAppServerV2.JSONRPC.Message) async throws {
        let connection = try #require(connections.last)
        try await send(message, on: connection)
    }

    func advertiseCancellation(_ supported: Bool) { cancelRequestCapability = supported }

    func advertiseProviders(_ providers: JSONValue?) { self.providers = providers }

    func fail(_ method: String, with error: CodexAppServerV2.JSONRPC.ErrorObject?) { failures[method] = error }

    func holdRequests(_ method: String) { heldMethods.insert(method) }

    func setResult(_ value: JSONValue, method: String) { results[method] = value }

    func failCapacity(_ method: String, count: Int, retryable: Bool) {
        capacityFailures[method] = (count, retryable)
    }

    func releaseRequests(result: JSONValue) async throws {
        let held = heldRequests
        heldRequests.removeAll()
        heldMethods.removeAll()
        for (request, connection) in held {
            try await send(.response(.init(id: request.id, result: result)), on: connection)
        }
    }

    func refuseHeldRequestsForCapacity() async throws {
        let held = heldRequests
        heldRequests.removeAll()
        for (request, connection) in held {
            try await send(.error(.init(error: .init(code: -32001, data: .object([
                "kind": .string("capacity"), "retryable": .bool(true)]), message: "Capacity reached"),
                id: request.id)), on: connection)
        }
    }

    func setHistoryResult(_ value: JSONValue) {
        currentHistoryResult = value
    }

    func rejectContentSubscriptions(code: Int64) {
        contentSubscriptionRejection = code
    }

    func acceptContentSubscriptions() {
        contentSubscriptionRejection = nil
    }

    func holdContentSubscriptionReplies() {
        contentSubscriptionRepliesHeld = true
    }

    func releaseContentSubscriptionReply() async throws {
        let (id, connection) = try #require(heldContentSubscriptionReplies.first)
        heldContentSubscriptionReplies.removeFirst()
        try await send(.response(.init(id: id, result: .object([:]))), on: connection)
    }

    private func send(_ message: CodexAppServerV2.JSONRPC.Message, on connection: NWConnection) async throws {
        let data = try JSONEncoder().encode(message)
        let context = NWConnection.ContentContext(identifier: "jsonrpc", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func sendLargeFrame(_ request: CodexAppServerV2.JSONRPC.Request, on connection: NWConnection,
                                transfer: LargeTransfer) async throws {
        let response = CodexAppServerV2.JSONRPC.Message.response(.init(id: request.id,
            result: .object(["padding": .string(String(repeating: "x", count: 65_536))])))
        let data = try JSONEncoder().encode(response)
        try await send(.notification(.init(method: "connection/largeFrame",
            params: .object(["bytes": .number(Double(data.count))]))), on: connection)
        let context = NWConnection.ContentContext(identifier: "dripped", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        let offsets = transfer == .completes ? Array(stride(from: 0, to: data.count, by: 4096)) : [0]
        for offset in offsets {
            let end = min(offset + 4096, data.count)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data.subdata(in: offset..<end), contentContext: context, isComplete: end == data.count,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
            }
            if transfer == .completes { try await Task.sleep(for: .milliseconds(500)) }
        }
    }

    func stop() {
        stopped = true
        for connection in connections { connection.cancel() }
        connections.removeAll()
        listener.cancel()
        requestStream.continuation.finish()
        notificationStream.continuation.finish()
        pingStream.continuation.finish()
    }
}
