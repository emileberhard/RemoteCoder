import Foundation

actor ConversationMetadataStore {
    private let url: URL

    init(hostID: UUID?, storage: HostStorage = .live) {
        url = storage.directory(for: .target(hostID: hostID))
            .appending(path: "codex-session-metadata.json")
    }

    func load() throws -> SessionMetadataLocalState { try Self.load(from: url) }

    nonisolated static func load(from url: URL) throws -> SessionMetadataLocalState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionMetadataLocalState() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode([ConversationMetadata].self, from: data)
            var entries: [String: ConversationMetadata] = [:]
            for entry in legacy {
                guard entries[entry.sessionID] == nil else { throw Failure.invalidLegacyMetadata }
                entries[entry.sessionID] = entry
            }
            return SessionMetadataLocalState(legacy: entries)
        }
        struct Header: Decodable { let version: Int }
        switch try decoder.decode(Header.self, from: data).version {
        case 2: decoder.dateDecodingStrategy = .iso8601
        case 3: decoder.dateDecodingStrategy = .deferredToDate
        default: throw Failure.unsupportedVersion
        }
        var state = try decoder.decode(SessionMetadataLocalState.self, from: data)
        state.version = 3
        return state
    }

    func save(_ state: SessionMetadataLocalState) throws { try Self.save(state, to: url) }

    nonisolated static func save(_ state: SessionMetadataLocalState, to url: URL) throws {
        guard state.version == 3 else { throw Failure.unsupportedVersion }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    enum Failure: LocalizedError {
        case unsupportedVersion, invalidLegacyMetadata
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This settings file was written by an unsupported app version. It has not been replaced."
            case .invalidLegacyMetadata: "The settings file has conflicting records. It has not been replaced."
            }
        }
    }
}
