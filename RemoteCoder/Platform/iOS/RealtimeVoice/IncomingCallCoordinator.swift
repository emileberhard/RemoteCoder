import AVFoundation
import Foundation
@preconcurrency import PushKit

@MainActor
final class IncomingCallCoordinator: NSObject, @preconcurrency PKPushRegistryDelegate {
    private let workspace: ChatWorkspaceModel
    private let voiceCalls: VoiceCallCenter
    private var registry: PKPushRegistry?

    init(workspace: ChatWorkspaceModel, voiceCalls: VoiceCallCenter) {
        self.workspace = workspace
        self.voiceCalls = voiceCalls
        super.init()
    }

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        self.registry = registry
        registry.delegate = self
        refreshMicrophonePermission()
    }

    func refreshMicrophonePermission() {
        let permitted = AVAudioApplication.shared.recordPermission == .granted
        registry?.desiredPushTypes = permitted ? [.voIP] : []
        workspace.pushTokens.setMicrophonePermitted(permitted)
    }

    func pushRegistry(
        _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
    ) {
        guard type == .voIP else { return }
        workspace.pushTokens.receiveVoIP(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        workspace.pushTokens.invalidateVoIP()
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingVoIPPushWith payload: PKPushPayload,
        metadata: PKVoIPPushMetadata,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        receive(payload, mustReport: metadata.mustReport, completion: completion)
    }

    private func receive(_ payload: PKPushPayload, mustReport: Bool, completion: @escaping () -> Void) {
        let push: AgentCallPush?
        if let value = payload.dictionaryPayload["agentCall"],
           let data = try? JSONSerialization.data(withJSONObject: value) {
            push = try? JSONDecoder().decode(AgentCallPush.self, from: data)
        } else {
            push = nil
        }
        let model = push.flatMap { workspace.incomingCallModel(routingID: $0.hostId) }
        AgentCallDiagnostics.record(
            "pushReceived", callID: push?.callId, hostID: push?.hostId,
            detail: "mustReport=\(mustReport) decoded=\(push != nil) ownerResolved=\(model != nil)", error: nil
        )
        Task { @MainActor in
            await self.voiceCalls.call.receiveIncoming(
                push: push, model: model, deviceID: workspace.pushTokens.deviceID, mustReport: mustReport
            )
            // No gateway handshake or selected-chat bootstrap holds the PushKit completion.
            completion()
            AgentCallDiagnostics.record(
                "pushCompleted", callID: push?.callId, hostID: push?.hostId, detail: "", error: nil
            )
        }
    }
}
