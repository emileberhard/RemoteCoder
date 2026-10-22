import Foundation

enum RealtimeVoiceInitialItemsLimits {
    static let maximumItems = 128
    static let maximumEstimatedTokens = 8_192
    static let bytesPerEstimatedToken = 4
    static let truncationMarker = "\n…earlier continuity truncated…\n"
}

struct RealtimeVoiceHistoryMessage: Sendable {
    let role: RealtimeVoiceRole
    let text: String
    let date: Date

    init(role: RealtimeVoiceRole, text: String, date: Date = .distantPast) {
        self.role = role
        self.text = text
        self.date = date
    }
}

enum RealtimeVoiceConversationHistory {
    static func initialItems(
        from messages: [RealtimeVoiceHistoryMessage]
    ) -> [RealtimeVoiceInitialItem] {
        var remainingTokens = RealtimeVoiceInitialItemsLimits.maximumEstimatedTokens
        var newestFirst: [RealtimeVoiceInitialItem] = []

        for message in messages.reversed() {
            guard newestFirst.count < RealtimeVoiceInitialItemsLimits.maximumItems,
                  remainingTokens > 0
            else { break }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let estimatedTokens = tokenEstimate(for: text)
            let boundedText: String
            if estimatedTokens <= remainingTokens {
                boundedText = text
            } else {
                boundedText = truncate(
                    text,
                    maximumBytes: remainingTokens * RealtimeVoiceInitialItemsLimits.bytesPerEstimatedToken
                )
            }
            guard !boundedText.isEmpty else { continue }
            newestFirst.append(RealtimeVoiceInitialItem(
                role: message.role,
                text: boundedText
            ))
            remainingTokens -= tokenEstimate(for: boundedText)
        }

        return Array(newestFirst.reversed())
    }

    static func merged(
        chatMessages: [RealtimeVoiceHistoryMessage],
        voiceMessages: [RealtimeVoiceHistoryMessage]
    ) -> [RealtimeVoiceHistoryMessage] {
        let ordered = (chatMessages + voiceMessages).enumerated().sorted { lhs, rhs in
            if lhs.element.date == rhs.element.date {
                return lhs.offset < rhs.offset
            }
            return lhs.element.date < rhs.element.date
        }.map(\.element)

        return ordered.reduce(into: []) { result, message in
            let normalized = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            if let previous = result.last,
               previous.role == message.role,
               previous.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
                return
            }
            result.append(message)
        }
    }

    private static func tokenEstimate(for text: String) -> Int {
        text.utf8.count.quotientAndRemainder(dividingBy: RealtimeVoiceInitialItemsLimits.bytesPerEstimatedToken).quotient
            + (text.utf8.count.isMultiple(of: RealtimeVoiceInitialItemsLimits.bytesPerEstimatedToken) ? 0 : 1)
    }

    private static func truncate(_ text: String, maximumBytes: Int) -> String {
        let marker = RealtimeVoiceInitialItemsLimits.truncationMarker
        let markerBytes = marker.utf8.count
        guard maximumBytes > markerBytes else { return "" }

        let bytes = Array(text.utf8)
        guard bytes.count > maximumBytes else { return text }

        let contentBudget = maximumBytes - markerBytes
        let prefixBudget = contentBudget / 4
        let suffixBudget = contentBudget - prefixBudget
        let prefix = validUTF8Prefix(bytes, maximumCount: prefixBudget)
        let suffix = validUTF8Suffix(bytes, maximumCount: suffixBudget)
        return prefix + marker + suffix
    }

    private static func validUTF8Prefix(_ bytes: [UInt8], maximumCount: Int) -> String {
        var end = min(maximumCount, bytes.count)
        while end > 0, String(bytes: bytes[..<end], encoding: .utf8) == nil {
            end -= 1
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    private static func validUTF8Suffix(_ bytes: [UInt8], maximumCount: Int) -> String {
        var start = max(0, bytes.count - maximumCount)
        while start < bytes.count, String(bytes: bytes[start...], encoding: .utf8) == nil {
            start += 1
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}
