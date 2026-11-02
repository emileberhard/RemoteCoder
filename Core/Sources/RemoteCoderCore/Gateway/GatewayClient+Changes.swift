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

    func readCheckouts(threadID: String?, directory: String) async throws -> CheckoutDiscovery {
        struct Request: Encodable {
            let threadId: String?
            let directory: String
        }
        return try await callDecodable(
            method: "changes/checkouts",
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
