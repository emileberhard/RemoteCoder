import Foundation

/// The ChatGPT desktop client's reply format for `request_user_input_async`
/// questions. RemoteCoder sends the same envelope so an answer from the phone
/// shows as answered on the desktop and the other way round:
///
/// ```
/// <send_user_message_question_reply>
/// [{"questionItemId":"[\"request_user_input_async\",\"<call id>\",0]","question":"…","answer":"…"}]
/// </send_user_message_question_reply>
/// ```
///
/// The fork's core does not parse the envelope; the model reads it as text.
enum QuestionReplyEnvelope {
    static let openTag = "<send_user_message_question_reply>"
    static let closeTag = "</send_user_message_question_reply>"
    static let toolName = "request_user_input_async"

    /// One decoded reply: which item and question it answers.
    struct Entry: Codable, Hashable, Sendable {
        let itemID: String
        let index: Int
        let reply: QuestionReply
    }

    private struct WireReply: Codable {
        let questionItemId: String
        let question: String
        let answer: String
    }

    /// Composes one envelope for every question of one item, in question order.
    static func text(itemID: String, replies: [QuestionReply]) -> String {
        text(entries: replies.enumerated().map { Entry(itemID: itemID, index: $0.offset, reply: $0.element) })
    }

    static func text(entries: [Entry]) -> String {
        let wire = entries.map { entry in
            WireReply(questionItemId: questionItemID(itemID: entry.itemID, index: entry.index),
                      question: entry.reply.question, answer: entry.reply.answer)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding plain strings cannot fail; an empty array is the only fallback needed by the type system.
        let json = (try? encoder.encode(wire)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "\(openTag)\n\(json)\n\(closeTag)"
    }

    /// Desktop identifies a question by a JSON array serialised into a string.
    static func questionItemID(itemID: String, index: Int) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [toolName, itemID, index] as [Any],
                                               options: [.withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\(toolName)\",\"\(itemID)\",\(index)]"
    }

    /// Nil when the text is not an envelope. Accepts a single object or an
    /// array like desktop, and drops entries that do not name an async question.
    static func parse(_ text: String) -> [Entry]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(openTag), trimmed.hasSuffix(closeTag) else { return nil }
        let body = trimmed.dropFirst(openTag.count).dropLast(closeTag.count)
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return nil }
        let objects: [[String: Any]]
        if let array = object as? [[String: Any]] { objects = array }
        else if let single = object as? [String: Any] { objects = [single] }
        else { return nil }
        return objects.compactMap { entry in
            guard let rawID = entry["questionItemId"] as? String, let (itemID, index) = parseQuestionItemID(rawID),
                  let question = entry["question"] as? String, let answer = entry["answer"] as? String else { return nil }
            return Entry(itemID: itemID, index: index, reply: QuestionReply(question: question, answer: answer))
        }
    }

    static func parseQuestionItemID(_ raw: String) -> (itemID: String, index: Int)? {
        guard let parts = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any], parts.count == 3,
              parts[0] as? String == toolName, let itemID = parts[1] as? String, let index = parts[2] as? Int,
              index >= 0 else { return nil }
        return (itemID, index)
    }
}
