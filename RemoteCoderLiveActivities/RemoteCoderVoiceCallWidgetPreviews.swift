#if DEBUG
import SwiftUI
import WidgetKit

private typealias CallState = RemoteCoderVoiceCallAttributes.ContentState

private extension RemoteCoderVoiceCallAttributes {
    static let fixture = RemoteCoderVoiceCallAttributes(
        callID: UUID(uuidString: "6F1C2A4B-3D5E-4F70-8A91-B2C3D4E5F607") ?? UUID(),
        startedAt: .now.addingTimeInterval(-252),
        hostName: "Mac mini"
    )
}

private extension CallState {
    static let speaking = CallState(phase: .speaking, isMuted: false, title: "Fix login flow",
        caption: "I've started the test run on the Mini. I'll tell you when it's green.")
    static let listening = CallState(phase: .listening, isMuted: false, title: "Fix login flow",
        caption: "Tests passed. Want me to open a pull request?")
    static let muted = CallState(phase: .listening, isMuted: true, title: "Fix login flow", caption: nil)
    static let connecting = CallState(phase: .connecting, isMuted: false, title: nil, caption: nil)
    static let reconnectingLongHost = CallState(phase: .reconnecting, isMuted: false, title: "Refactor the gateway journal",
        caption: "I'll pick up where we left off once the connection is back and the build has finished on the Mini.")
}

private extension RemoteCoderVoiceCallAttributes {
    static let longHost = RemoteCoderVoiceCallAttributes(
        callID: UUID(uuidString: "6F1C2A4B-3D5E-4F70-8A91-B2C3D4E5F608") ?? UUID(),
        startedAt: .now.addingTimeInterval(-3_725),
        hostName: "emils-macbook-pro-build-host"
    )
}

#Preview("Lock Screen speaking", as: .content, using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.speaking
}

#Preview("Lock Screen muted", as: .content, using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.muted
}

#Preview("Lock Screen connecting", as: .content, using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.connecting
}

#Preview("Lock Screen reconnecting, long host", as: .content, using: RemoteCoderVoiceCallAttributes.longHost) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.reconnectingLongHost
}

#Preview("Expanded listening", as: .dynamicIsland(.expanded), using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.listening
}

#Preview("Expanded muted", as: .dynamicIsland(.expanded), using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.muted
}

#Preview("Compact speaking", as: .dynamicIsland(.compact), using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.speaking
}

#Preview("Minimal muted", as: .dynamicIsland(.minimal), using: RemoteCoderVoiceCallAttributes.fixture) {
    RemoteCoderVoiceCallWidget()
} contentStates: {
    CallState.muted
}
#endif
