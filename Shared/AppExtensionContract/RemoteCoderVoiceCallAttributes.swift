import ActivityKit
import Foundation

struct RemoteCoderVoiceCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case connecting
            case listening
            case speaking
            case reconnecting
        }

        var phase: Phase
        var isMuted: Bool
        var title: String?
        var caption: String?
    }

    let callID: UUID
    let startedAt: Date
    let hostName: String
}
