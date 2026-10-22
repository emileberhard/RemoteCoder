import Foundation

enum ConversationMetadataSource: String, Codable, Sendable {
    case selection, runtime
}

struct ConversationMetadataSelection: Codable, Hashable, Sendable {
    let sessionID: String
    let modelID: String
    let reasoningSelectionID: String
    let fastModeEnabled: Bool?
    let source: ConversationMetadataSource?
}

struct ConversationMetadataMutation: Codable, Hashable, Sendable {
    let selection: ConversationMetadataSelection
    var expectedRevision: UInt64
    let mutationID: String

    private enum CodingKeys: String, CodingKey {
        case selection, expectedRevision
        case mutationID = "mutationId"
    }
}

struct ConversationMetadataRecord: Codable, Hashable, Sendable {
    let sessionID: String
    let modelID: String
    let reasoningSelectionID: String
    let fastModeEnabled: Bool?
    let source: ConversationMetadataSource?
    let updatedAt: Date
    let serverRevision: UInt64?
    let mutationID: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID, modelID, reasoningSelectionID, fastModeEnabled, source, updatedAt, serverRevision
        case mutationID = "mutationId"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        modelID = try values.decode(String.self, forKey: .modelID)
        reasoningSelectionID = try values.decode(String.self, forKey: .reasoningSelectionID)
        fastModeEnabled = try values.decodeIfPresent(Bool.self, forKey: .fastModeEnabled)
        source = try values.decodeIfPresent(ConversationMetadataSource.self, forKey: .source)
        updatedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .updatedAt))
        serverRevision = try values.decodeIfPresent(UInt64.self, forKey: .serverRevision)
        mutationID = try values.decodeIfPresent(String.self, forKey: .mutationID)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(modelID, forKey: .modelID)
        try values.encode(reasoningSelectionID, forKey: .reasoningSelectionID)
        try values.encodeIfPresent(fastModeEnabled, forKey: .fastModeEnabled)
        try values.encodeIfPresent(source, forKey: .source)
        try values.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
        try values.encodeIfPresent(serverRevision, forKey: .serverRevision)
        try values.encodeIfPresent(mutationID, forKey: .mutationID)
    }
}
