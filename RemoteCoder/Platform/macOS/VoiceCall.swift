#if os(macOS)
import Foundation
import Observation

@Observable
@MainActor
final class VoiceCall {
    static let syncedPreferenceKeys: Set<String> = []

    let state: RealtimeVoiceLifecycle.State = .idle
    let isActive = false
    let callOwner: ExecutionTarget? = nil
    let liveCallID: UUID? = nil
    let conversationContext: RealtimeVoiceConversationContext? = nil

    func isActive(for owner: ExecutionTarget) -> Bool { false }

    func stop() async {}

    func reloadSelectedVoice() {}

    func start(using model: any VoiceCallHost, resuming context: RealtimeVoiceConversationContext? = nil) async {}

    func startWithLiveActivity(using model: any VoiceCallHost, hostName: String) async throws {}

    func applyConversationSettings(_ settings: ConversationSettingsUpdate, hostID: UUID) {}

    func incomingSettingsRevision(for context: RealtimeVoiceConversationContext, hostID: UUID) -> UInt64? { nil }

    func acceptConversationReadback(threadID: String, realtimeSessionID: String, hostID: UUID) {}
}
#endif
