import Foundation

protocol HostDirectoryRemote: Actor {
    func readHostInfo() async throws -> GatewayClient.HostInfoResponse
    func readDirectory(path: String) async throws -> CodexAppServerV2.FsReadDirectoryResponse
    func readDirectoryFavorites() async throws -> DirectoryFavorites
    func updateDirectoryFavorites(_ changes: [DirectoryFavoriteChange]) async throws -> DirectoryFavorites
}

extension GatewayClient: HostDirectoryRemote {
    func readDirectoryFavorites() async throws -> DirectoryFavorites {
        try await callDecodable(
            method: "directory/favorites/read",
            params: encodeToJSONValue(GatewayRequestParams.Empty()),
            timeout: timeouts.request
        )
    }

    func updateDirectoryFavorites(_ changes: [DirectoryFavoriteChange]) async throws -> DirectoryFavorites {
        struct Request: Encodable { let changes: [DirectoryFavoriteChange] }
        return try await callDecodable(
            method: "directory/favorites/update",
            params: encodeToJSONValue(Request(changes: changes)),
            timeout: timeouts.request
        )
    }
}
