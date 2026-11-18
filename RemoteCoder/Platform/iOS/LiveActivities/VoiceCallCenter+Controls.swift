import Foundation

extension VoiceCallCenter: VoiceCallControls {
    func setMuted(_ muted: Bool, callID: UUID) async {
        guard call.liveCallID == callID else { return }
        await call.setMuted(muted)
    }

    func endCall(callID: UUID) async {
        guard call.liveCallID == callID else { return }
        await call.stop()
    }
}
