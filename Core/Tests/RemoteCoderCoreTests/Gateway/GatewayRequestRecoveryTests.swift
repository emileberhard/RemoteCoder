import Foundation
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct GatewayRequestRecoveryTests {
    @Test(arguments: [true, false, nil] as [Bool?])
    func cancelledSentReadUsesOnlyAdvertisedCapability(_ capability: Bool?) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        if let capability { await fixture.advertiseCancellation(capability) }
        await fixture.holdRequests("thread/read")
        let gateway = try await connected(fixture)
        do {
            let read = Task { try await gateway.readThread(threadID: "abandoned", includeTurns: false) }
            let request = try await nextRequest("thread/read", fixture: fixture)
            read.cancel()
            await #expect(throws: CancellationError.self) { try await read.value }
            _ = try await gateway.call(method: "host/info", params: nil, timeout: .seconds(1))
            let cancellations = await fixture.recordedNotifications.filter { $0.method == "$/cancelRequest" }
            #expect(cancellations.count == (capability == true ? 1 : 0))
            if capability == true {
                let id = try #require(cancellations.first?.params?.objectValue?["id"])
                if case .integer(let sentID) = request.id { #expect(id == .number(Double(sentID))) }
                else { Issue.record("The client must send an integer request ID") }
                try await fixture.send(.error(.init(error: .init(code: -32800,
                    data: .object(["kind": .string("requestCancelled"), "retryable": .bool(false)]),
                    message: "Request cancelled"), id: request.id)))
                _ = try await gateway.call(method: "host/info", params: nil, timeout: .seconds(1))
                #expect(await gateway.isConnected)
            }
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test(arguments: ["turn/start", "turn/steer", "thread/queue/add", "command/exec"])
    func abandoningCommandsDelegatesCancellationToTheGateway(_ method: String) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.advertiseCancellation(true)
        await fixture.holdRequests(method)
        let gateway = try await connected(fixture)
        do {
            let command = Task { try await gateway.call(method: method, params: nil, timeout: .seconds(1)) }
            _ = try await nextRequest(method, fixture: fixture)
            command.cancel()
            await #expect(throws: CancellationError.self) { try await command.value }
            _ = try await gateway.call(method: "host/info", params: nil, timeout: .seconds(1))
            #expect(await fixture.recordedNotifications.filter { $0.method == "$/cancelRequest" }.count == 1)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test(arguments: ["conversation/agents/list", "turn/start"], [true, false])
    func requestTimeoutCancelsTheExactRemoteRequestOnlyWithCapability(_ method: String, _ capability: Bool) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.advertiseCancellation(capability)
        await fixture.holdRequests(method)
        let gateway = try await connected(fixture)
        do {
            let call = Task { try await gateway.call(method: method, params: nil, timeout: .milliseconds(100)) }
            let request = try await nextRequest(method, fixture: fixture)
            do {
                _ = try await call.value
                Issue.record("A held request must time out")
            } catch let error as GatewayClient.ClientError {
                guard case .requestTimedOut(let timedOutMethod) = error else { throw error }
                #expect(timedOutMethod == method)
            }
            _ = try await gateway.call(method: "host/info", params: nil, timeout: .seconds(1))
            let cancellations = await fixture.recordedNotifications.filter { $0.method == "$/cancelRequest" }
            #expect(cancellations.count == (capability ? 1 : 0))
            if capability {
                if case .integer(let id) = request.id {
                    #expect(cancellations.first?.params?.objectValue?["id"] == .number(Double(id)))
                } else { Issue.record("The client must send an integer request ID") }
            }
            #expect(await gateway.isConnected)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test func cancellationBeforeSendingAndAfterConnectionReplacementSendsNothing() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.advertiseCancellation(true)
        await fixture.holdRequests("thread/read")
        let gateway = try await connected(fixture)
        do {
            let gate = ReadStartGate()
            let notSent = Task {
                await gate.wait()
                return try await gateway.readThread(threadID: "never-sent", includeTurns: false)
            }
            await gate.started()
            notSent.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await notSent.value }
            let old = Task { try await gateway.readThread(threadID: "old-connection", includeTurns: false) }
            _ = try await nextRequest("thread/read", fixture: fixture)
            let original = await gateway.connectionIdentity
            await gateway.disconnect()
            await fixture.advertiseCancellation(false)
            try await gateway.connectIfNeeded()
            #expect(await gateway.connectionIdentity != original)
            old.cancel()
            _ = await old.result
            let replacement = Task { try await gateway.readThread(threadID: "new-connection", includeTurns: false) }
            _ = try await nextRequest("thread/read", fixture: fixture)
            replacement.cancel()
            await #expect(throws: CancellationError.self) { try await replacement.value }
            _ = try await gateway.call(method: "host/info", params: nil, timeout: .seconds(1))
            #expect(await fixture.recordedRequests.filter { $0.method == "thread/read" }.count == 2)
            #expect(await fixture.recordedNotifications.allSatisfy { $0.method != "$/cancelRequest" })
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test(arguments: [(0, 1), (2, 3), (20, 4)])
    func retryableReadsRecoverOrStopAfterThreeRetries(failures: Int, expectedRequests: Int) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.failCapacity("thread/read", count: failures, retryable: true)
        let gateway = try await connected(fixture)
        do {
            let result = await Result { try await gateway.readThread(threadID: "read", includeTurns: false) }
            if failures < 4 { #expect(try result.get().thread.id == "read") }
            else { #expect(throws: GatewayRPCFailure.self) { try result.get() } }
            #expect(await fixture.recordedRequests.filter { $0.method == "thread/read" }.count == expectedRequests)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test(arguments: ["turn/start", "turn/steer", "thread/queue/add", "command/exec", "unknown/read"])
    func gatewayRefusalsAllowBoundedRetriesForAnyMethod(_ method: String) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.failCapacity(method, count: 20, retryable: true)
        let gateway = try await connected(fixture)
        await #expect(throws: GatewayRPCFailure.self) {
            try await gateway.call(method: method, params: nil, timeout: .seconds(10))
        }
        #expect(await fixture.recordedRequests.filter { $0.method == method }.count == 4)
        await gateway.retire()
        await fixture.stop()
    }

    @Test(arguments: ["thread/read", "turn/start"])
    func nonretryableCapacityNeverRetries(_ method: String) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let gateway = try await connected(fixture)
        await fixture.failCapacity(method, count: 20, retryable: false)
        await #expect(throws: GatewayRPCFailure.self) {
            try await gateway.call(method: method, params: nil, timeout: .seconds(1))
        }
        #expect(await fixture.recordedRequests.filter { $0.method == method }.count == 1)
        await gateway.retire()
        await fixture.stop()
    }

    @Test func retriesShareTheOriginalRecoveryDeadline() async throws {
        let attempts = ReadAttempts()
        await #expect(throws: GatewayRPCFailure.self) {
            try await GatewayRequestRecovery.run(method: "thread/read", timeout: .milliseconds(10)) { _ -> Bool in
                await attempts.record()
                try await Task.sleep(for: .milliseconds(20))
                throw try #require(GatewayRPCFailure(code: -32001, message: "Full",
                    data: .object(["kind": .string("capacity"), "retryable": .bool(true)])))
            }
        }
        #expect(await attempts.count == 1)
    }

    @Test func cancellationStopsCapacityRecovery() async throws {
        let attempts = ReadAttempts()
        let task = Task {
            try await GatewayRequestRecovery.run(method: "thread/read", timeout: .seconds(1)) { _ -> Bool in
                await attempts.record()
                throw try #require(GatewayRPCFailure(code: -32001, message: "Full",
                    data: .object(["kind": .string("capacity"), "retryable": .bool(true)])))
            }
        }
        await attempts.started()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await attempts.count == 1)
    }

    private func connected(_ fixture: DeviceToolSocketFixture) async throws -> GatewayClient {
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do { try await gateway.connectIfNeeded(); return gateway }
        catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    private func nextRequest(_ method: String, fixture: DeviceToolSocketFixture) async throws -> CodexAppServerV2.JSONRPC.Request {
        for await request in fixture.requests where request.method == method { return request }
        throw GatewayClient.ClientError.connectionClosed
    }
}

private actor ReadStartGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var observed: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            waiting = $0
            observed?.resume()
            observed = nil
        }
    }
    func started() async { if waiting == nil { await withCheckedContinuation { observed = $0 } } }
    func open() { waiting?.resume(); waiting = nil }
}

private actor ReadAttempts {
    private(set) var count = 0
    private var observed: CheckedContinuation<Void, Never>?
    func record() { count += 1; observed?.resume(); observed = nil }
    func started() async { if count == 0 { await withCheckedContinuation { observed = $0 } } }
}
