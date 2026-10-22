import AVFoundation
import Foundation
@preconcurrency import LiveCommunicationKit
@preconcurrency import WebRTC

/// LiveCommunicationKit explicitly supports fulfilling actions from asynchronous
/// delegate work, but its reference types don't yet declare `Sendable` in the iOS 27 SDK.
/// This immutable box is the only transfer boundary; the action is consumed on MainActor.
private struct SystemConversationAction: @unchecked Sendable {
    let value: ConversationAction
}

/// Keep the SDK's unannotated `ConversationManager` behind one immutable, sendable
/// boundary instead of weakening isolation for the voice controller itself.
private final class SystemConversationManager: @unchecked Sendable {
    let value: ConversationManager

    init(configuration: ConversationManager.Configuration) {
        value = ConversationManager(configuration: configuration)
    }

    func perform(_ action: SystemConversationAction) async throws {
        try await value.perform([action.value])
    }

    func reportIncoming(callID: UUID) async throws {
        let handle = Handle(type: .generic, value: "remotecoder-voice", displayName: "RemoteCoder")
        try await value.reportNewIncomingConversation(
            uuid: callID,
            update: Conversation.Update(members: [handle], activeRemoteMembers: [handle], capabilities: [])
        )
    }
}

@MainActor
enum RealtimeVoiceAudioSession {
    static func configureForSystemCall() throws {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        // WebRTC's default configuration alone does not configure AVAudioSession.
        // Apply the duplex category before answering; iOS still owns activation.
        try session.setCategory(
            AVAudioSession.Category(rawValue: configuration.category),
            mode: AVAudioSession.Mode(rawValue: configuration.mode),
            options: configuration.categoryOptions
        )
    }
}

enum CallEndReason {
    case failed
    case remoteEnded
    case joinedElsewhere
}

@MainActor
protocol CallSystemBridgeDelegate: AnyObject {
    func callSystemDidReset() async
    func callSystem(perform action: ConversationAction) async
    func callSystemTimedOut(callID: UUID) async
    func callSystemDidActivateAudio(category: String, mode: String)
    func callSystemDidDeactivateAudio()
}

@MainActor
final class CallSystemBridge: NSObject {
    private static let remoteHandle = Handle(
        type: .generic,
        value: "remotecoder-voice",
        displayName: "RemoteCoder"
    )

    private static let configuration = ConversationManager.Configuration(
        ringtoneName: nil,
        iconTemplateImageData: nil,
        maximumConversationGroups: 1,
        maximumConversationsPerConversationGroup: 1,
        includesConversationInRecents: false,
        supportsVideo: false,
        supportedHandleTypes: [.generic],
        supportsAudioTranslation: false
    )

    private enum BridgeError: LocalizedError {
        case noSystemConversation

        var errorDescription: String? {
            "The system call is no longer available."
        }
    }

    weak var delegate: (any CallSystemBridgeDelegate)?
    private nonisolated let diagnosticID: String
    private var manager: SystemConversationManager?
    private var conversationsBeingCreated = 0
    private var hasForwardedAudioActivation = false

    init(diagnosticID: String) {
        self.diagnosticID = diagnosticID
        super.init()
    }

    func hasConversation(_ callID: UUID) -> Bool {
        conversation(for: callID) != nil
    }

    func startOutgoing(callID: UUID) async throws {
        let action = StartConversationAction(
            conversationUUID: callID,
            handles: [Self.remoteHandle],
            isVideo: false
        )
        let manager = managerForNewConversation()
        conversationsBeingCreated += 1
        defer { conversationsBeingCreated -= 1 }
        try await manager.perform(SystemConversationAction(value: action))
    }

    func requestEnd(callID: UUID) async throws {
        let action = EndConversationAction(conversationUUID: callID)
        try await currentManager().perform(SystemConversationAction(value: action))
    }

    func requestMute(_ isMuted: Bool, callID: UUID) async throws {
        let action = MuteConversationAction(
            conversationUUID: callID,
            isMuted: isMuted
        )
        try await currentManager().perform(SystemConversationAction(value: action))
    }

    func reportIncoming(callID: UUID) async throws {
        let manager = managerForNewConversation()
        conversationsBeingCreated += 1
        defer { conversationsBeingCreated -= 1 }
        try await manager.reportIncoming(callID: callID)
    }

    func reportStartedConnecting(callID: UUID) {
        report(.conversationStartedConnecting(.now), callID: callID)
    }

    func reportConnected(callID: UUID) {
        report(.conversationConnected(.now), callID: callID)
    }

    func reportEnded(callID: UUID, reason: CallEndReason) {
        switch reason {
        case .failed:
            report(.conversationEnded(.now, .failed), callID: callID)
        case .remoteEnded:
            report(.conversationEnded(.now, .remoteEnded), callID: callID)
        case .joinedElsewhere:
            report(.conversationEnded(.now, .joinedElsewhere), callID: callID)
        }
    }

    private func managerForNewConversation() -> SystemConversationManager {
        if let manager,
           conversationsBeingCreated > 0 || manager.value.conversations.contains(where: { $0.state != .left }) {
            VoiceModeDiagnostics.log(
                "realtime controller=\(diagnosticID) system manager kept creating=\(conversationsBeingCreated) "
                    + "conversations=\(Self.conversationStateSummary(manager.value))"
            )
            return manager
        }
        let replaced = manager != nil
        let balancedActivation = hasForwardedAudioActivation
        balanceForwardedAudioActivation()
        manager?.value.delegate = nil
        manager?.value.invalidate()
        let fresh = SystemConversationManager(configuration: Self.configuration)
        fresh.value.delegate = self
        manager = fresh
        VoiceModeDiagnostics.log(
            "realtime controller=\(diagnosticID) system manager created replaced=\(replaced) "
                + "balancedActivation=\(balancedActivation)"
        )
        return fresh
    }

    private func forwardAudioActivation() {
        hasForwardedAudioActivation = true
        RTCAudioSession.sharedInstance().audioSessionDidActivate(AVAudioSession.sharedInstance())
    }

    private func balanceForwardedAudioActivation() {
        guard hasForwardedAudioActivation else { return }
        hasForwardedAudioActivation = false
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.isAudioEnabled = false
        rtcAudioSession.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
    }

    private func currentManager() throws -> SystemConversationManager {
        guard let manager else { throw BridgeError.noSystemConversation }
        return manager
    }

    private func isCurrent(_ source: ObjectIdentifier) -> Bool {
        manager.map { ObjectIdentifier($0.value) } == source
    }

    private func currentDelegate(for source: ObjectIdentifier) -> (any CallSystemBridgeDelegate)? {
        isCurrent(source) ? delegate : nil
    }

    private func report(_ event: Conversation.Event, callID: UUID) {
        guard let manager, let conversation = conversation(for: callID) else { return }
        manager.value.reportConversationEvent(event, for: conversation)
    }

    private func conversation(for uuid: UUID) -> Conversation? {
        manager?.value.conversations.first { $0.uuid == uuid }
    }
}

extension CallSystemBridge: ConversationManagerDelegate {
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        conversationChanged conversation: Conversation
    ) {
        VoiceModeDiagnostics.log(
            "realtime controller=\(diagnosticID) system conversation changed "
                + "uuid=\(conversation.uuid.uuidString) state=\(conversation.state.rawValue) "
                + "pendingActions=\(manager.pendingActions.count)"
        )
    }

    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {
        VoiceModeDiagnostics.log(
            "realtime controller=\(diagnosticID) system manager began "
                + "conversations=\(Self.conversationStateSummary(manager))"
        )
    }

    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        let source = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            await self?.currentDelegate(for: source)?.callSystemDidReset()
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        perform action: ConversationAction
    ) {
        let systemAction = SystemConversationAction(value: action)
        let source = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            let action = systemAction.value
            guard let delegate = self?.currentDelegate(for: source) else {
                action.fail()
                return
            }
            await delegate.callSystem(perform: action)
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        timedOutPerforming action: ConversationAction
    ) {
        let systemAction = SystemConversationAction(value: action)
        let source = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            let action = systemAction.value
            action.fail()
            await self?.currentDelegate(for: source)?.callSystemTimedOut(callID: action.conversationUUID)
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        didActivate audioSession: AVAudioSession
    ) {
        VoiceModeDiagnostics.log(
            "realtime controller=\(diagnosticID) system audio session activated "
                + "conversations=\(Self.conversationStateSummary(manager))"
        )
        let activatedCategory = audioSession.category.rawValue
        let activatedMode = audioSession.mode.rawValue
        let source = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(source) else { return }
            self.forwardAudioActivation()
            guard let delegate = self.delegate else {
                RTCAudioSession.sharedInstance().isAudioEnabled = false
                return
            }
            delegate.callSystemDidActivateAudio(category: activatedCategory, mode: activatedMode)
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        didDeactivate audioSession: AVAudioSession
    ) {
        VoiceModeDiagnostics.log(
            "realtime controller=\(diagnosticID) system audio session deactivated "
                + "conversations=\(Self.conversationStateSummary(manager))"
        )
        let source = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(source) else { return }
            self.balanceForwardedAudioActivation()
            self.delegate?.callSystemDidDeactivateAudio()
        }
    }

    nonisolated private static func conversationStateSummary(
        _ manager: ConversationManager
    ) -> String {
        manager.conversations
            .map { "\($0.uuid.uuidString.prefix(8)):\($0.state.rawValue)" }
            .joined(separator: ",")
    }
}
