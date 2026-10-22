import Testing
@testable import RemoteCoderCore

struct ComposerSendStateTests {
    private func state(input: String = "", attachments: Bool = false, preparing: Bool = false,
                       working: Bool = false, canSteer: Bool = false, blocked: Bool = false) -> ComposerSendState {
        ComposerSendState(input: input, hasAttachments: attachments, isPreparingAttachments: preparing,
                          isWorking: working, canSteer: canSteer, isBlocked: blocked)
    }

    @Test func textOrAnAttachmentAloneEnablesSend() {
        #expect(state(input: "  \n ") == .idle)
        #expect(state(input: " hi ") == .send)
        #expect(state(attachments: true) == .send)
    }

    @Test func attachmentsStillPreparingDisableSendEvenWithText() {
        #expect(!state(input: "hi", preparing: true).canSend)
        #expect(state(input: "hi", preparing: true, working: true) == .working)
    }

    @Test func aBlockedComposerNeverSends() {
        #expect(!state(input: "hi", canSteer: true, blocked: true).canSend)
        #expect(state(input: "hi", blocked: true) == .blocked)
    }

    @Test func aRunningTurnTurnsSendIntoSteering() {
        #expect(state(input: "hi", working: true, canSteer: true) == .steer)
        #expect(state(input: "hi", working: true) == .send)
    }
}
