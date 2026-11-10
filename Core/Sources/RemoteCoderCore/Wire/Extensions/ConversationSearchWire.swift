import Foundation

struct ConversationSearchParams: Encodable, Sendable {
    let query: String
    let limit: Int
}

struct ConversationSearchResponse: Decodable, Sendable {
    static let schemaVersion = 1

    struct Conversation: Decodable, Sendable {
        let sessionKey: String
        let hostId: UUID
        let provider: AgentProvider
        let threadId: String
        let title: String?
        let cwd: String?
        let lastAt: Date?
        let titleMatch: Bool
        let hitCount: Int
        let hits: [Hit]
    }

    struct Hit: Decodable, Sendable {
        let excerpt: String
    }

    let schemaVersion: Int
    let conversations: [Conversation]

    static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        for style in [Date.ISO8601FormatStyle(), Date.ISO8601FormatStyle(includingFractionalSeconds: true)] {
            if let date = try? style.parse(text) { return date }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid timestamp \(text)"))
    }
}
