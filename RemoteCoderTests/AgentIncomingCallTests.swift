import Foundation
import CallKit
import AVFoundation
@preconcurrency import WebRTC
import Testing
@testable import RemoteCoder

struct AgentIncomingCallTests {
    private let callID = UUID(uuidString: "A8D0FD55-F9DC-48A2-8874-F49C08D728E1")!
    private let hostID = UUID(uuidString: "33D01743-A5F8-443B-A180-B5918096398C")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    @Test func systemCallPreparationAppliesDuplexAudioBeforeActivation() async throws {
        let session = RTCAudioSession.sharedInstance()
        let category = session.category
        let mode = session.mode
        let options = session.categoryOptions
        let manual = session.useManualAudio
        let enabled = session.isAudioEnabled
        defer {
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            try? session.setCategory(AVAudioSession.Category(rawValue: category), mode: AVAudioSession.Mode(rawValue: mode), options: options)
            session.useManualAudio = manual
            session.isAudioEnabled = enabled
        }
        do {
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            try session.setCategory(.ambient, mode: .default, options: [])
        }
        let wasActive = session.isActive
        try RealtimeVoiceAudioSession.configureForSystemCall()
        #expect(session.category == AVAudioSession.Category.playAndRecord.rawValue)
        #expect(session.mode == AVAudioSession.Mode.voiceChat.rawValue)
        #expect(session.useManualAudio)
        #expect(!session.isAudioEnabled)
        #expect(session.isActive == wasActive)
    }

    @Test func incomingFailureNamesFocusWithoutLosingTheProviderCode() async throws {
        let error = NSError(domain: CXErrorDomainIncomingCall, code: 3)
        let failure = AgentCallFailure(error)
        #expect(failure.reason == "filteredByDoNotDisturb")
        #expect(failure.domain == CXErrorDomainIncomingCall)
        #expect(failure.code == 3)
        let record = AgentCallDiagnostic(
            ts: now, uptime: 42, processID: 123, callId: callID, hostId: hostID,
            stage: "reportIncomingFailed", detail: "", failure: failure
        )
        let json = try #require(JSONSerialization.jsonObject(with: record.encodedLine()) as? [String: Any])
        #expect(json["recordType"] as? String == "agentCall")
        #expect(json["callId"] as? String == callID.uuidString)
        #expect(json["ts"] as? String == "2027-01-15T08:00:00.000Z")
        #expect((json["failure"] as? [String: Any])?["reason"] as? String == "filteredByDoNotDisturb")
    }

    @Test func callDiagnosticSurvivesWithoutAnOSLogDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        let record = AgentCallDiagnostic(
            ts: now, uptime: 42, processID: 123, callId: callID, hostId: hostID,
            stage: "pushReceived", detail: "mustReport=true", failure: nil
        )
        try await exporter.enqueue(line: record.encodedLine(), kind: "call")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let stored = try #require(files.first { $0.lastPathComponent.hasSuffix("-call.jsonl") })
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stored)) as? [String: Any])
        #expect(json["callId"] as? String == callID.uuidString)
        #expect(json["stage"] as? String == "pushReceived")
    }

    @Test func pushRequiresARealIdentityAndNumericExpiry() async throws {
        let data = Data(#"{"callId":"a8d0fd55-f9dc-48a2-8874-f49c08d728e1","hostId":"33d01743-a5f8-443b-a180-b5918096398c","expiresAt":1800000060}"#.utf8)
        let push = try JSONDecoder().decode(AgentCallPush.self, from: data)
        #expect(push.callId == callID)
        #expect(push.hostId == hostID)
        #expect(push.isCurrent(at: now))
        #expect(!push.isCurrent(at: now.addingTimeInterval(60)))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentCallPush.self, from: Data(#"{"callId":"not-a-call","hostId":"33d01743-a5f8-443b-a180-b5918096398c","expiresAt":1800000060}"#.utf8))
        }
    }

    @Test func answeredContextUsesOnlyTheOriginAndNeverSeedsSelectedChatHistory() async throws {
        let push = AgentCallPush(callId: callID, hostId: hostID, expiresAt: 1_800_000_060)
        let status = AgentCallStatus(
            callId: callID, conversationThreadId: "claude_original", provider: "claude",
            state: .ringing, expiresAt: push.expiresAt, cwd: "/tmp/original",
            model: "opus", effort: "high"
        )
        let context = try status.voiceContext(for: push, at: now)
        #expect(context.threadID == "claude_original")
        #expect(context.realtimeSessionID == callID.uuidString.lowercased())
        #expect(context.cwd == "/tmp/original")
        #expect(context.model == "opus")
        #expect(context.effort == "high")
        #expect(context.history.isEmpty)
        #expect(context.initialItems.isEmpty)
        #expect(!context.isProvisionalThread)
    }

    @Test func staleWrongOrEndedCallCannotCreateVoiceContext() async {
        let push = AgentCallPush(callId: callID, hostId: hostID, expiresAt: 1_800_000_060)
        for (id, state, expiry, provider) in [
            (hostID, AgentCallStatus.State.ringing, push.expiresAt, "codex"),
            (callID, .ended, push.expiresAt, "codex"),
            (callID, .unresolved, push.expiresAt, "codex"),
            (callID, .ending, push.expiresAt, "codex"),
            (callID, .connected, push.expiresAt, "codex"),
            (callID, .ringing, now.timeIntervalSince1970, "codex"),
            (callID, .ringing, push.expiresAt, "claude"),
        ] {
            let status = AgentCallStatus(
                callId: id, conversationThreadId: "original", provider: provider,
                state: state, expiresAt: expiry, cwd: "/tmp/original", model: "test", effort: nil
            )
            #expect(throws: AgentIncomingCallError.self) { try status.voiceContext(for: push, at: now) }
        }
    }

    @MainActor
    @Test func reconcilingHostsRetiresAChangedEndpointBeforeChoosingAGateway() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let oldModel = try #require(fixture.workspace.model(for: fixture.mini.id))
        var replacement = fixture.mini
        replacement.hostname = "replacement.invalid"
        fixture.workspace.settings.upsert(replacement)
        #expect(fixture.workspace.model(for: fixture.mini.id) === oldModel)
        // Reconciling closes the old admission immediately.
        fixture.workspace.reconcileHosts()
        #expect(oldModel.isRetired)
        await fixture.workspace.finishHostChanges()
        let current = try #require(fixture.workspace.model(for: fixture.mini.id))
        #expect(current !== oldModel)
        #expect(oldModel.isRetired)
        #expect(current.host.hasSameConnection(as: replacement))
    }

    @MainActor
    @Test func enrollmentPreservesIdentityAcrossRenamesAndRejectsSilentReplacement() async throws {
        let suite = "AgentIncomingCallTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var host = GatewayHostConfiguration(
            id: hostID, name: "Original", hostname: "original.invalid", port: 1234, authToken: "test"
        )
        let settings = HostStore(hosts: [host], activeHostID: hostID, defaults: defaults, credentials: MemoryGatewayCredentials())
        try settings.enrollIncomingCalls(host: host, serverHostID: callID)
        host.name = "Renamed"
        settings.upsert(host)
        #expect(settings.hosts[0].incomingCallHostID == callID)
        #expect(throws: AgentIncomingCallError.self) {
            try settings.enrollIncomingCalls(host: host, serverHostID: hostID)
        }
        #expect(settings.hosts[0].incomingCallHostID == callID)
        host.hostname = "replacement.invalid"
        settings.upsert(host)
        #expect(settings.hosts[0].incomingCallHostID == nil)
    }
}
