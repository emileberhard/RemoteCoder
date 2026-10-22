import Foundation

enum RealtimeVoiceRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

struct RealtimeVoiceInitialItem: Codable, Sendable {
    let role: RealtimeVoiceRole
    let text: String
}
