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

    func readChangeSummary(threadID: String, directory: String) async throws -> ChangeSummary {
        struct Request: Encodable {
            let threadId: String
            let directory: String
        }
        return try await callDecodable(
            method: "changes/summary",
            params: encodeToJSONValue(Request(threadId: threadID, directory: directory)),
            timeout: timeouts.history
        )
    }

    func readTurnChanges(threadID: String) async throws -> TurnChangesRead {
        struct Request: Encodable {
            let threadId: String
        }
        return try await callDecodable(
            method: "changes/turn",
            params: encodeToJSONValue(Request(threadId: threadID)),
            timeout: timeouts.history
        )
    }
}
