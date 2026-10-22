import Foundation

/// A request to bring one question card into view; a new token per request.
struct QuestionFocusRequest: Equatable, Sendable {
    let itemID: String
    let token: Int
}
