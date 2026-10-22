import Foundation
import Testing
@testable import RemoteCoder

/// What a dispatched turn's end, a foreign or replayed turn, and a lost socket
/// each do to busy state, the send and the audio route. They run against the
/// real chat model and `FakeGatewayServer` so they hold across any change to
/// how the model learns that its own turn ended.
@MainActor
struct TurnCompletionBoundaryTests {
    private static let thread = "019a3333-0000-7000-8000-000000000004"

    @Test(.timeLimit(.minutes(1))) func aCompletedTurnEndsItsJobAndSpeaksItsFinalReply() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openChat(fixture)
        let speech = speakingReplies(on: chat)
        defer { speech.cancel() }
        try await dispatch("Hi", from: chat, to: gateway)

        try await gateway.notify("item/completed", agentMessage("Hello there", itemID: "answer"))
        try await gateway.notify("turn/completed", completion(status: "completed"))

        #expect(try await waitUntil { chat.currentReplyDelivery == .idle })
        #expect(chat.target.historyBusySessionIDs.isEmpty)
        #expect(try await waitUntil { Self.isEngaged(speech) })
    }

    @Test(.timeLimit(.minutes(1))) func aFailedTurnEndsItsJobWithoutSpeaking() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openChat(fixture)
        let speech = speakingReplies(on: chat)
        defer { speech.cancel() }
        try await dispatch("Hi", from: chat, to: gateway)

        try await gateway.notify("turn/completed", completion(status: "failed", error: "Rate limit reached"))

        #expect(try await waitUntil { chat.currentReplyDelivery == .idle })
        #expect(chat.target.historyBusySessionIDs.isEmpty)
        #expect(Self.isQuiet(speech))
    }

    @Test(.timeLimit(.minutes(1))) func aCompletedTurnWithoutTextEndsQuietly() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openChat(fixture)
        let speech = speakingReplies(on: chat)
        defer { speech.cancel() }
        try await dispatch("Hi", from: chat, to: gateway)

        try await gateway.notify("turn/completed", completion(status: "completed"))

        #expect(try await waitUntil { chat.currentReplyDelivery == .idle })
        #expect(chat.target.historyBusySessionIDs.isEmpty)
        #expect(Self.isQuiet(speech))
        #expect(!chat.messages.contains { $0.text.contains("empty response") })
    }

    @Test(.timeLimit(.minutes(1))) func aTurnThatCompletesBeforeTheStartReplyIsNeverLeftBusy() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openChat(fixture)
        await gateway.holdTurnStarts()
        #expect(await chat.prepareDraft())
        chat.input = "Hi"
        #expect(await chat.send())
        await gateway.waitForHeldTurnStart()

        try await gateway.notify("turn/completed", completion(status: "completed"))
        try? await Task.sleep(for: .milliseconds(300))
        await gateway.releaseTurnStart()

        #expect(try await waitUntil { chat.currentReplyDelivery == .idle })
        #expect(chat.target.historyBusySessionIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aForeignTurnNeverSpeaksAndNeverEndsTheDispatchedJob() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openChat(fixture)
        let speech = speakingReplies(on: chat)
        defer { speech.cancel() }
        try await dispatch("Hi", from: chat, to: gateway)

        try await gateway.notify("item/completed", agentMessage("From another client", itemID: "foreign", turnID: "turn-other"))
        try await gateway.notify("turn/completed", completion(status: "completed", turnID: "turn-other"))
        try await gateway.notify("turn/completed", completion(status: "completed"))

        #expect(try await waitUntil { chat.currentReplyDelivery == .idle })
        #expect(Self.isQuiet(speech))
    }

    @Test(.timeLimit(.minutes(1))) func aReplayedCompletionEndsTheJobButNeverSpeaks() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openChat(fixture)
        let speech = speakingReplies(on: chat)
        defer { speech.cancel() }
        try await dispatch("Hi", from: chat, to: gateway)
        await chat.target.handleScenePhaseInactive()
        try #require(chat.target.observation.state(of: Self.thread) == .detached)

        for (method, params) in [
            ("item/completed", agentMessage("Said while the app was away", itemID: "answer")),
            ("turn/completed", completion(status: "completed")),
        ] {
            let note = CodexGatewayNotification(method: method, params: .object(params), server: ServerNotification.decode(method: method, params: .object(params)))
            await chat.target.apply(gatewayEvent: try #require(GatewayNotificationRouting.route(note)), replay: true)
        }

        #expect(chat.target.historyBusySessionIDs.isEmpty)
        #expect(Self.isQuiet(speech))
    }

    @Test(.timeLimit(.minutes(1))) func aLostConnectionBeforeTheStartReplyLeavesTheSendReportedNotDelivered() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp() }
        let chat = try await openChat(fixture)
        await gateway.holdTurnStarts()
        #expect(await chat.prepareDraft())
        chat.input = "Hi"
        #expect(await fixture.workspace.send(from: chat))
        await gateway.waitForHeldTurnStart()

        await gateway.stop()

        #expect(try await waitUntil { chat.messages.contains { $0.text.hasPrefix("⛔️") } })
        #expect(try await waitUntil { chat.currentReplyDelivery == .idle })
        #expect(chat.target.historyBusySessionIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aLostConnectionAfterTheStartReplyKeepsTheTurnBusyUntilItIsReconciled() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.thread, model: CodexModelFixtures.solID)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp() }
        let chat = try await openChat(fixture)
        try await dispatch("Hi", from: chat, to: gateway)

        await gateway.stop()

        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(chat.currentReplyDelivery == .acknowledged)
        #expect(chat.target.historyBusySessionIDs == [Self.thread])
        #expect(!chat.messages.contains { $0.text.hasPrefix("⛔️") })
    }

    private func openChat(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let workspace = fixture.workspace
        let chat = try #require(workspace.screen(for: fixture.mini.id))
        await chat.target.conversationList.record(ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: Data(#"""
            {"id":"\#(Self.thread)","preview":"Test","modelProvider":"openai","model":"\#(CodexModelFixtures.solID)","createdAt":0,
             "updatedAt":1,"cwd":"/repo","cliVersion":"test","source":"appServer","status":{"type":"notLoaded"},
             "ephemeral":false,"turns":[]}
            """#.utf8))))
        workspace.selectConversation(at: .init(hostID: fixture.mini.id, threadID: Self.thread))
        try #require(workspace.selectedScreen === chat)
        Task { await chat.target.prepareIfNeeded() }
        try #require(await waitUntil {
            chat.loadingTranscriptID == nil && chat.areConversationSettingsReady && chat.currentConversationDispatchBlock == nil
        })
        chat.dismissAlert()
        return chat
    }

    private func dispatch(_ text: String, from chat: ChatScreenModel, to gateway: FakeGatewayServer) async throws {
        #expect(await chat.prepareDraft())
        chat.input = text
        #expect(await chat.send())
        try #require(await waitUntil { await gateway.turnStarts == [.init(threadID: Self.thread, text: text)] })
        try #require(await waitUntil { chat.currentReplyDelivery == .acknowledged })
        await chat.target.dispatcher.drain()
    }

    private func speakingReplies(on chat: ChatScreenModel) -> VoiceOutputController {
        let suiteName = "TurnCompletionBoundaryTests.\(UUID().uuidString)"
        let preferences = SpeechPreferences(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
        preferences.isAutoSpeakEnabled = true
        chat.target.speech = VoiceOutputController(access: .fixture, preferences: preferences)
        return chat.target.speech
    }

    private static func isEngaged(_ speech: VoiceOutputController) -> Bool {
        speech.isPreparing || speech.isSpeaking || speech.lastError != nil
    }

    private static func isQuiet(_ speech: VoiceOutputController) -> Bool { !isEngaged(speech) }

    private func completion(status: String, error: String? = nil, turnID: String = "turn-1") -> [String: JSONValue] {
        var turn: [String: JSONValue] = ["id": .string(turnID), "status": .string(status)]
        if let error { turn["error"] = .object(["message": .string(error)]) }
        return ["threadId": .string(Self.thread), "turnId": .string(turnID), "turn": .object(turn)]
    }

    private func agentMessage(_ text: String, itemID: String, turnID: String = "turn-1") -> [String: JSONValue] {
        ["threadId": .string(Self.thread), "turnId": .string(turnID),
         "item": .object(["type": .string("agentMessage"), "id": .string(itemID), "text": .string(text)])]
    }
}
