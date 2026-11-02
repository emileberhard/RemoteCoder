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
}
