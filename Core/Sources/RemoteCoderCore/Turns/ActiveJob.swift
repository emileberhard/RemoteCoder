import Foundation

struct ActiveJob: Identifiable, Equatable, Sendable {
    let id: String
    let threadID: String
}
