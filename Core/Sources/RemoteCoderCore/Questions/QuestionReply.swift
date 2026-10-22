import Foundation

/// One answered question, kept on the reply bubble and on the resolved card.
struct QuestionReply: Codable, Hashable, Sendable {
    let question: String
    let answer: String

    /// The text a reply bubble shows and speaks: the answers alone, in order.
    static func displayText(_ replies: [QuestionReply]) -> String {
        replies.map(\.answer).joined(separator: "\n\n")
    }
}
