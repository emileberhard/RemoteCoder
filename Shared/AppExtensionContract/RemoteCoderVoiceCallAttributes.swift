import ActivityKit
import Foundation

struct RemoteCoderVoiceCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}

    let callID: UUID
    let startedAt: Date
    let hostName: String
}
