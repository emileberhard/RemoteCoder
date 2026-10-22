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
    func fetchRemoteMetadata() async throws -> [String: ConversationMetadata]
    func updateRemoteMetadata(_ mutation: ConversationMetadataMutation) async throws -> ConversationMetadata
}
