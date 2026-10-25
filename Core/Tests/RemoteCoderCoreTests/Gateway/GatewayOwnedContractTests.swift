import Foundation
import Testing
@testable import RemoteCoderCore

struct GatewayOwnedContractTests {
    @Test func anUnavailableLiveActivityProjectionReachesTheApplicationRouter() {
        let note = GatewayEventFixture.notification(method: "daemon/liveActivity/changed", params: .null, receivedAt: .now)
        guard case .liveActivity(let snapshot) = GatewayNotificationRouting.route(note) else {
            Issue.record("Unavailable Live Activity projection was discarded")
            return
        }
        #expect(snapshot == nil)
    }

    @Test(arguments: [1, 2, 3])
    func accountDirectoryRequiresTheCurrentSchema(_ schema: Int) throws {
        let data = Data("{\"schemaVersion\":\(schema),\"accounts\":[],\"refreshing\":false,\"retiredClaudeAccountIds\":[]}".utf8)
        if schema == 2 {
            let directory = try JSONDecoder().decode(AccountDirectoryResponse.self, from: data)
            #expect(directory.accounts.isEmpty)
            #expect(directory.retiredClaudeAccountIds.isEmpty)
        } else {
            #expect(throws: AccountServiceError.self) { try JSONDecoder().decode(AccountDirectoryResponse.self, from: data) }
        }
    }

    @Test func nullStartActivityRetainsTheRunningTurn() throws {
        let activity = try JSONDecoder().decode(CodexGatewayDaemon.ActiveTurnsResponse.self,
            from: fixture("active-turn-null-start"))
        #expect(activity.activeTurns.count == 1)
        #expect(activity.activeTurns[0].startedAtUnixSeconds == nil)
        #expect(activity.externalActivity.sessions.isEmpty)
        #expect(activity.agentOwners.isEmpty)
    }

    @Test(arguments: ["externalActivity", "agentOwners"])
    func missingActivityCoverageDoesNotDecodeAsEmpty(_ key: String) throws {
        let original = try #require(JSONSerialization.jsonObject(with: fixture("active-turn-null-start")) as? [String: Any])
        var missing = original
        missing.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CodexGatewayDaemon.ActiveTurnsResponse.self, from: data)
        }
    }

    @Test(arguments: [nil, "complete", "unavailable"] as [String?])
    func agentOwnerCoverageAcceptsOlderGateways(_ coverage: String?) throws {
        var payload = try #require(JSONSerialization.jsonObject(with: fixture("active-turn-null-start")) as? [String: Any])
        payload["agentOwnersCoverage"] = coverage
        let data = try JSONSerialization.data(withJSONObject: payload)
        let activity = try JSONDecoder().decode(CodexGatewayDaemon.ActiveTurnsResponse.self, from: data)

        #expect(activity.agentOwnersCoverage?.rawValue == coverage)
    }

    @Test func metadataPayloadsRoundTripTheSharedRustFixtures() throws {
        let mutationData = try fixture("metadata-update")
        let mutation = try JSONDecoder().decode(ConversationMetadataMutation.self, from: mutationData)
        #expect(mutation.expectedRevision == 7)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mutation)) == JSONDecoder().decode(JSONValue.self, from: mutationData))
        let recordData = try fixture("metadata-record")
        let record = try JSONDecoder().decode(ConversationMetadataRecord.self, from: recordData)
        #expect(ConversationMetadata(record).selection == mutation.selection)
        #expect(record.mutationID == mutation.mutationID)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record)) == JSONDecoder().decode(JSONValue.self, from: recordData))
    }

    @Test(arguments: ["metadata-conflict", "voice-call-ended", "request-capacity"])
    func errorsUseMachineKindsRatherThanTheirHumanMessage(_ name: String) throws {
        struct Envelope: Decodable { let error: CodexAppServerV2.JSONRPC.ErrorObject }
        let error = try JSONDecoder().decode(Envelope.self, from: fixture(name)).error
        let failure = try #require(GatewayRPCFailure(code: Int(error.code), message: "A translated message", data: error.data))
        switch name {
        case "metadata-conflict":
            #expect(failure.kind == .metadataConflict)
            #expect(failure.currentMetadata?.serverRevision == 8)
        case "voice-call-ended":
            #expect(failure.kind == .voiceCallEnded)
            #expect(!failure.retryable)
        default:
            #expect(failure.kind == .capacity)
            #expect(failure.retryable)
        }
        #expect(GatewayRPCFailure(code: -32603, message: "voice call already ended by the agent", data: nil) == nil)
    }

    @Test(arguments: [
        ("turn-not-running", GatewayRPCFailure.Kind.turnNotRunning(threadID: "thread-1", turnID: "turn-1"), false),
        ("history-cursor-invalid", .historyCursorInvalid, false),
        ("history-page-too-large", .historyPageTooLarge(actualBytes: 33_000_000, limitBytes: 25_165_824), false),
        ("conversation-busy", .conversationBusy(retryAfterMs: 2000), true),
        ("queue-change-uncertain", .queueChangeUncertain, false),
        ("input-delivery-uncertain", .inputDeliveryUncertain, false),
        ("provider-unavailable", .providerUnavailable(provider: .codex, reason: "Codex sign-in needed on mac-mini"), false),
    ])
    func gatewayErrorKindsDecodeFromTheSharedFixtures(_ name: String, _ kind: GatewayRPCFailure.Kind, _ retryable: Bool) throws {
        struct Envelope: Decodable { let error: CodexAppServerV2.JSONRPC.ErrorObject }
        let error = try JSONDecoder().decode(Envelope.self, from: fixture(name)).error
        let failure = try #require(GatewayRPCFailure(code: Int(error.code), message: error.message, data: error.data))

        #expect(failure.kind == kind)
        #expect(failure.retryable == retryable)
    }

    @Test func anUnavailableProviderFailureReadsAsItsHealthReason() throws {
        struct Envelope: Decodable { let error: CodexAppServerV2.JSONRPC.ErrorObject }
        let error = try JSONDecoder().decode(Envelope.self, from: fixture("provider-unavailable")).error
        let failure = try #require(GatewayRPCFailure(code: Int(error.code), message: error.message, data: error.data))

        #expect(failure.localizedDescription == "Codex sign-in needed on mac-mini")
    }

    @Test func providerHealthDecodesFromTheSharedFixture() throws {
        let frame = try fixture("provider-health")
        guard case .providerHealthChanged(let health) = ServerNotification.decode(method: "gateway/providerHealth", frame: frame) else {
            Issue.record("Expected gateway/providerHealth"); return
        }
        #expect(health.status(of: .codex) == .fallback(route: "copilot", reason: "Codex subscription sign-in failed"))
        #expect(health.status(of: .claude) == .unavailable(reason: "Claude Code is not signed in on mac-mini"))
    }

    @Test func theActivitySnapshotDecodesItsEpochCoverageAndStartSequence() throws {
        let snapshot = try JSONDecoder().decode(CodexGatewayDaemon.ActiveTurnsResponse.self, from: fixture("coverage"))

        #expect(snapshot.epoch == "6f0f4b1e-2c1a-4f6e-9d55-0a1b2c3d4e5f")
        #expect(snapshot.revision == 2)
        #expect(snapshot.coverage == .init(codex: false, claude: true))
        #expect(snapshot.activeTurns.map(\.startedAtSequence) == [41])
        #expect(snapshot.canConfirmInactivity(for: "claude_thread"))
        #expect(!snapshot.canConfirmInactivity(for: "codex_thread"))
    }

    @Test func aKindThisAppDoesNotKnowStaysAnUnknownFailure() throws {
        let failure = try #require(GatewayRPCFailure(code: -32600, message: "Newer", data: .object([
            "kind": .string("somethingNew"), "retryable": .bool(true)
        ])))
        #expect(failure.kind == .unknown("somethingNew"))
    }

    @Test func historyPageFailurePreservesMeasuredSize() throws {
        let failure = try #require(GatewayRPCFailure(code: -32003, message: "Page exceeds budget", data: .object([
            "kind": .string("historyPageTooLarge"), "retryable": .bool(false),
            "actualBytes": .number(33_000_000), "limitBytes": .number(24_000_000)
        ])))
        #expect(failure.kind == .historyPageTooLarge(actualBytes: 33_000_000, limitBytes: 24_000_000))
    }

    @Test func identityPersistenceWarningReachesTheApplicationRouter() throws {
        let note = GatewayEventFixture.notification(method: "gateway/warning", params: .object([
            "kind": .string("historyIdentityPersistence"), "threadId": .string("claude_fixture"),
            "message": .string("History identity could not be saved.")
        ]), receivedAt: .now)
        guard case .warning(let warning) = GatewayNotificationRouting.route(note) else {
            Issue.record("The warning was discarded"); return
        }
        #expect(warning.threadId == "claude_fixture")
        #expect(warning.kind == .historyIdentityPersistence)
    }

    @Test(arguments: [42, nil] as [UInt64?])
    func liveRoutingCarriesTheGatewaySequenceStamp(sequence: UInt64?) throws {
        let note = GatewayEventFixture.notification(method: "turn/started", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
        ]), sequence: sequence)
        guard case .turnEvent(let event) = try #require(GatewayNotificationRouting.route(note)) else {
            Issue.record("turn/started did not route as a turn event"); return
        }
        #expect(event.sequence == sequence)
    }

    @Test func aMalformedItemStillReachesTheTurnWithoutAnItem() throws {
        let note = GatewayEventFixture.notification(method: "item/completed", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "item": .object(["type": .string("agentMessage"), "id": .string("a")]),
        ]))
        guard case .turnEvent(let event) = try #require(GatewayNotificationRouting.route(note)) else {
            Issue.record("A malformed item was not routed to its turn"); return
        }
        #expect(event.item == nil)
        #expect(event.turnID == "turn-1")
    }

    private func fixture(_ name: String) throws -> Data {
        try ProtocolFixtures.data(named: name)
    }
}
