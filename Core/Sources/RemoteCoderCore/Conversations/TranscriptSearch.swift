import Foundation

enum TranscriptSearch {
    static func matchingRowIDs(_ query: String, in items: [ChatStreamItem]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return items.compactMap { item in
            guard case .message(let message) = item,
                  searchableText(of: message).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { return nil }
            return item.id
        }
    }

    private static func searchableText(of message: ChatMessage) -> String {
        guard let replies = message.questionReplies, !replies.isEmpty else { return message.text }
        return replies.map { "\($0.question)\n\($0.answer)" }.joined(separator: "\n\n")
    }
}
