import Foundation

struct ConversationMetadata: Codable, Hashable, Sendable {
    typealias Source = ConversationMetadataSource
    let sessionID: String
    var modelID: String
    var reasoningSelectionID: String
    var fastModeEnabled: Bool? = nil
    var source: Source? = nil
    var updatedAt: Date
    var serverRevision: UInt64? = nil
    var mutationID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case sessionID, modelID, reasoningSelectionID, fastModeEnabled, source, updatedAt, serverRevision
        case mutationID = "mutationId"
    }

    var selection: ConversationMetadataSelection {
        ConversationMetadataSelection(sessionID: sessionID, modelID: modelID,
            reasoningSelectionID: reasoningSelectionID, fastModeEnabled: fastModeEnabled, source: source)
    }
}

extension ConversationMetadata {
    init(_ record: ConversationMetadataRecord) {
        self.init(sessionID: record.sessionID, modelID: record.modelID, reasoningSelectionID: record.reasoningSelectionID,
            fastModeEnabled: record.fastModeEnabled, source: record.source, updatedAt: record.updatedAt,
            serverRevision: record.serverRevision, mutationID: record.mutationID)
    }
}

extension ConversationMetadataSelection {
    func localMetadata(updatedAt: Date) -> ConversationMetadata {
        ConversationMetadata(sessionID: sessionID, modelID: modelID, reasoningSelectionID: reasoningSelectionID,
            fastModeEnabled: fastModeEnabled, source: source, updatedAt: updatedAt)
    }
}

struct SessionMetadataPending: Codable, Hashable, Sendable {
    var mutation: ConversationMetadataMutation
    let createdAt: Date
    var metadata: ConversationMetadata { mutation.selection.localMetadata(updatedAt: createdAt) }
}

struct SessionMetadataObservation: Codable, Equatable, Sendable {
    let metadata: ConversationMetadata
    var acknowledgedRevision: UInt64?
}

struct SessionMetadataLocalState: Codable, Equatable, Sendable {
    var version = 3
    var acknowledged: [String: ConversationMetadata] = [:]
    var pending: [String: SessionMetadataPending] = [:]
    var invalidated: Set<String>? = nil
    var observed: [String: SessionMetadataObservation]? = nil
    // Old caches did not distinguish unsent edits from acknowledged values.
    // Keep them until the first host read can reconcile that ambiguity safely.
    var legacy: [String: ConversationMetadata]? = nil
}

struct SessionMetadataStatus: Sendable, Equatable {
    var error: String?
    var conflicts: Set<String> = []
}

protocol ConversationMetadataRemote: Sendable {
    func fetchRemoteMetadata(knownRevision: String?) async throws -> ConversationMetadataSnapshot
    func updateRemoteMetadata(_ mutation: ConversationMetadataMutation) async throws -> ConversationMetadata
}

enum ConversationMetadataSnapshot: Decodable, Sendable {
    case full(entries: [String: ConversationMetadata], revision: String?)
    case unchanged(revision: String)

    private enum CodingKeys: String, CodingKey { case entries, revision, unchanged }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try values.decodeIfPresent(String.self, forKey: .revision)
        guard revision?.isEmpty != true else { throw GatewayClient.ClientError.invalidMessage }
        if try values.decodeIfPresent(Bool.self, forKey: .unchanged) == true {
            guard let revision, !values.contains(.entries) else { throw GatewayClient.ClientError.invalidMessage }
            self = .unchanged(revision: revision)
        } else {
            let records = try values.decode([ConversationMetadataRecord].self, forKey: .entries)
            var entries: [String: ConversationMetadata] = [:]
            for record in records {
                guard (record.serverRevision ?? 0) > 0, entries[record.sessionID] == nil else {
                    throw GatewayClient.ClientError.invalidMessage
                }
                entries[record.sessionID] = ConversationMetadata(record)
            }
            self = .full(entries: entries, revision: revision)
        }
    }
}

struct ConversationMetadataRefreshContext: Equatable, Sendable {
    let connectionID: UUID
    let foregroundGeneration: Int
}
