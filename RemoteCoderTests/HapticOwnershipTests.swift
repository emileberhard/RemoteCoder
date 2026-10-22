import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct HapticOwnershipTests {
    @Test func changingPresentationOrRetiringDropsDelayedFeedbackAndResetIsSilent() async {
        let fixture = HapticModelFixture()
        defer { await fixture.cleanUp() }
        fixture.model.setPresentation(TargetPresentation(presented: true))
        let first = fixture.model.target.feedbackForCurrentConversation()
        first(.commit)
        #expect(fixture.haptics.service.pulse?.event == .commit)
        let before = fixture.haptics.service.pulse?.id
        fixture.model.setPresentation(TargetPresentation(presented: false))
        fixture.model.setPresentation(TargetPresentation(presented: true))
        first(.error)
        #expect(fixture.haptics.service.pulse?.id == before)
        let second = fixture.model.target.feedbackForCurrentConversation()
        fixture.model.startNewConversation()
        second(.success)
        #expect(fixture.haptics.service.pulse?.id == before)
        let third = fixture.model.target.feedbackForCurrentConversation()
        fixture.model.target.beginRetirement()
        third(.success)
        #expect(fixture.haptics.service.pulse?.id == before)
    }

    @Test(arguments: [
        ("completed", .success), ("failed", .error), ("interrupted", nil), ("unknown", nil), ("new-provider-status", nil),
    ] as [(String, HapticEvent?)])
    func terminalFeedbackUsesTheActualResultAndIsNotRepeated(status: String, expected: HapticEvent?) async throws {
        let fixture = HapticModelFixture()
        defer { await fixture.cleanUp() }
        fixture.model.setPresentation(TargetPresentation(presented: true))
        fixture.model.setActiveSessionID("claude_test")
        let event = try completion(thread: "claude_test", status: status)
        await fixture.model.target.apply(gatewayEvent: event)
        #expect(fixture.haptics.service.pulse?.event == expected)
        let before = fixture.haptics.service.pulse?.id
        await fixture.model.target.apply(gatewayEvent: event)
        #expect(fixture.haptics.service.pulse?.id == before)
    }

    @Test func replayAndHiddenHostCompletionRemainSilent() async throws {
        let fixture = HapticModelFixture()
        defer { await fixture.cleanUp() }
        fixture.model.setActiveSessionID("claude_test")
        await fixture.model.target.apply(gatewayEvent: try completion(thread: "claude_test", status: "completed"))
        #expect(fixture.haptics.service.pulse == nil)
        fixture.model.setPresentation(TargetPresentation(presented: true))
        await fixture.model.target.apply(gatewayEvent: try completion(thread: "claude_test", status: "completed", turn: "2"), replay: true)
        #expect(fixture.haptics.service.pulse == nil)
    }

    @Test func attachmentFeedbackCannotFollowADifferentDraft() async throws {
        let fixture = HapticModelFixture()
        defer { await fixture.cleanUp() }
        fixture.model.setPresentation(TargetPresentation(presented: true))
        #expect(await fixture.model.prepareDraft())
        let draft = try #require(fixture.model.currentDraft)
        let feedback = fixture.model.attachmentFeedback(for: draft)
        fixture.model.startNewConversation()
        feedback(.commit)
        #expect(fixture.haptics.service.pulse == nil)
    }

    @Test(arguments: [true, false])
    func directStreamAndGlobalNotificationHaveOneOutcomeOwner(directFirst: Bool) async throws {
        let fixture = HapticModelFixture()
        defer { await fixture.cleanUp() }
        fixture.model.setPresentation(TargetPresentation(presented: true))
        fixture.model.setActiveSessionID("claude_test")
        let feedback = fixture.model.target.feedbackForCurrentConversation()
        let event = try completion(thread: "claude_test", status: "completed")
        if directFirst {
            fixture.model.target.reportTurnFeedback(threadID: "claude_test", turnID: "turn-1",
                                             outcome: .completed, replay: false, feedback: feedback)
            fixture.model.target.retireGatewayJob(threadID: "claude_test", turnID: "1", jobID: "test")
        } else {
            await fixture.model.target.apply(gatewayEvent: event)
        }
        let first = try #require(fixture.haptics.service.pulse)
        #expect(first.event == .success)
        if directFirst {
            await fixture.model.target.apply(gatewayEvent: event)
        } else {
            fixture.model.target.reportTurnFeedback(threadID: "claude_test", turnID: "turn-1",
                                             outcome: .completed, replay: false, feedback: feedback)
        }
        #expect(fixture.haptics.service.pulse?.id == first.id)
    }

    @Test func unknownOutcomeDoesNotConsumeALaterAuthoritativeResult() async {
        let fixture = HapticModelFixture()
        defer { await fixture.cleanUp() }
        fixture.model.setPresentation(TargetPresentation(presented: true))
        fixture.model.setActiveSessionID("claude_test")
        let feedback = fixture.model.target.feedbackForCurrentConversation()
        fixture.model.target.reportTurnFeedback(threadID: "claude_test", turnID: "1",
                                         outcome: .unknown, replay: false, feedback: feedback)
        #expect(fixture.haptics.service.pulse == nil)
        fixture.model.target.reportTurnFeedback(threadID: "claude_test", turnID: "1",
                                         outcome: .failed, replay: false, feedback: feedback)
        #expect(fixture.haptics.service.pulse?.event == .error)
    }

    private func completion(thread: String, status: String, turn: String = "1") throws -> RoutedGatewayEvent {
        try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "turn/completed",
            params: .object(["threadId": .string(thread), "turn": .object(["id": .string(turn), "status": .string(status)])]),
            receivedAt: .now, sequence: nil)))
    }
}

@MainActor
private struct HapticModelFixture {
    let haptics = HapticFixture()
    let temporaryStorage: TemporaryHostStorage
    let hostID = UUID()
    let target: ChatTargetModel
    let model: ChatScreenModel

    init() {
        let temporaryStorage = TemporaryHostStorage()
        self.temporaryStorage = temporaryStorage
        target = ChatTargetModel(host: GatewayHostConfiguration(id: hostID, name: "Haptic test",
            hostname: "127.0.0.1", port: 1, authToken: "test", transport: .trustedNetwork),
            chatDefaults: haptics.defaults, modelPickerPreferences: ModelPickerPreferences(defaults: haptics.defaults),
            syncedPreferences: SyncedPreferenceStore(defaults: haptics.defaults, keys: []),
            haptics: haptics.service,
            voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: temporaryStorage.storage, htmlVisuals: HTMLVisualServices(directory: temporaryStorage.storage.root.appending(path: "html-visuals")))
        model = target.makeScreen(newChat: UUID())
    }

    func cleanUp() async {
        await target.retire()
        temporaryStorage.cleanUp()
        haptics.cleanUp()
    }
}
