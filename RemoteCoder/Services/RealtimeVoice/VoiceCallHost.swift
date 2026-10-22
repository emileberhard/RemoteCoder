import Foundation

/// What `VoiceCall` needs from the chat model that owns a voice call, so it
/// never reaches into `ChatTargetModel`'s concrete storage or gateway.
@MainActor
protocol VoiceCallHost: AnyObject {
    var hostID: UUID { get }
    var activeSessionID: String? { get }
    var gatewayClient: GatewayClient { get }
    var voiceHistoryStore: RealtimeVoiceHistoryStore { get }

    func setVoiceModeActive(_ active: Bool)
    func prepareRealtimeVoiceConversation() async throws -> RealtimeVoiceConversationContext
    func refreshRealtimeVoiceConversation(
        _ context: RealtimeVoiceConversationContext, using voiceGateway: GatewayClient
    ) async throws -> RealtimeVoiceConversationContext
    func readIncomingVoiceSettings(
        _ context: RealtimeVoiceConversationContext,
        using voiceGateway: GatewayClient,
        ownsCall: @escaping @MainActor () -> Bool,
        readThread: @escaping @Sendable (String) async throws -> CodexAppServerV2.ThreadReadResponse
    ) async -> VoiceIncomingSettingsRead
    func discardProvisionalRealtimeVoiceConversation(threadID: String?) async
}

struct VoiceIncomingSettingsRead {
    let context: RealtimeVoiceConversationContext
    let readModelAndEffort: Bool
    let readFastMode: Bool
}
