import Foundation

extension GatewayClient {
    func readChanges(directory: String, source: ChangeSource) async throws -> ChangeRead {
        struct Request: Encodable {
            let directory: String
            let source: ChangeSource
        }
        return try await callDecodable(
            method: "changes/read",
            params: encodeToJSONValue(Request(directory: directory, source: source)),
            timeout: timeouts.history
        )
    }

    func readChangeSummary(threadID: String, directory: String, source: ChangeSource?) async throws -> ChangeSummary {
        struct Request: Encodable {
            let threadId: String
            let directory: String
            let source: ChangeSource?
        }
        return try await callDecodable(
            method: "changes/summary",
            params: encodeToJSONValue(Request(threadId: threadID, directory: directory, source: source)),
            timeout: timeouts.history
        )
    }

    func readTurnChanges(threadID: String, since anchor: ChangesAnchor?) async throws -> TurnChangesRead {
        struct Since: Encodable {
            let turnId: String
            let boundary: ChangesAnchor.Boundary
        }
        struct Request: Encodable {
            let threadId: String
            let since: Since?
        }
        return try await callDecodable(
            method: "changes/turn",
            params: encodeToJSONValue(Request(threadId: threadID,
                                              since: anchor.map { Since(turnId: $0.turnID, boundary: $0.boundary) })),
            timeout: timeouts.history
        )
    }
}
