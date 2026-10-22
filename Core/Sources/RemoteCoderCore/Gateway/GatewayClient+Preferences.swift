import Foundation

extension GatewayClient: SyncedPreferenceRemote {
    func readPreferences() async throws -> PreferenceDocument {
        try await callDecodable(
            method: "preferences/read",
            params: encodeToJSONValue(GatewayRequestParams.Empty()),
            timeout: timeouts.request
        )
    }

    func updatePreferences(_ entries: [String: PreferenceEntry]) async throws -> PreferenceDocument {
        struct Request: Encodable { let entries: [String: PreferenceEntry] }
        return try await callDecodable(
            method: "preferences/update",
            params: encodeToJSONValue(Request(entries: entries)),
            timeout: timeouts.request
        )
    }
}
