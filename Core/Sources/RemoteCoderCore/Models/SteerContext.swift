import Foundation

enum SteerContext {
    static let additionalContextKey = "remote_coder_steer_context"
    static let tailCharacterLimit = 600

    static func note(shownText: String?) -> String {
        let prefix = "RemoteCoder note: the user sent their latest message while your turn was still running. When they sent it, "
        guard let shownText, !shownText.isEmpty else {
            return prefix + "they had not yet seen any of your output from this turn."
        }
        let suffix = shownText.suffix(tailCharacterLimit + 1)
        var tail = suffix.suffix(tailCharacterLimit)
        if suffix.count > tailCharacterLimit, let preceding = suffix.first, !preceding.isWhitespace,
           tail.first?.isWhitespace == false {
            tail = tail.firstIndex(where: \.isWhitespace).map { tail[$0...] } ?? tail[tail.endIndex...]
        }
        let excerpt = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "the last of your output on their screen ended with: \"…\(excerpt)\". They had not seen anything you wrote after that."
    }

    static func capture(in items: [ChatStreamItem], turnID: String,
                        renderedSource: (ChatMessage) -> String) -> String {
        for case .message(let message) in items.reversed()
            where message.role == .codex {
            guard let canonicalTurnID = message.canonicalTurnID,
                  GatewayNotificationRouting.normalizeTurnID(canonicalTurnID) == GatewayNotificationRouting.normalizeTurnID(turnID) else { continue }
            let source = renderedSource(message)
            if !source.isEmpty { return note(shownText: source) }
        }
        return note(shownText: nil)
    }
}
