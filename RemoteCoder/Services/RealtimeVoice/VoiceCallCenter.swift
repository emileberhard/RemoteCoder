import Foundation

/// The app's one voice call and, through it, the one `CallSystemBridge` that owns
/// LiveCommunicationKit's `ConversationManager`. The app model creates one center
/// and every construction path receives it rather than starting a second one.
@MainActor
final class VoiceCallCenter {
    let call = VoiceCall()
}
