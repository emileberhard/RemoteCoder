import Foundation

protocol ConversationMarksRemote: Actor {
    func readConversationMarks() async throws -> ConversationMarks
    func updateConversationMarks(_ changes: [ConversationMarkChange]) async throws -> ConversationMarks?
    func resolveProjects(directories: [String]) async throws -> [ProjectIdentity]
}

extension GatewayClient: ConversationMarksRemote {
    func readConversationMarks() async throws -> ConversationMarks {
        try await callDecodable(
            method: "conversation/marks/read",
            params: encodeToJSONValue(GatewayRequestParams.Empty()),
            timeout: timeouts.request
        )
    }

    func updateConversationMarks(_ changes: [ConversationMarkChange]) async throws -> ConversationMarks? {
        struct Request: Encodable { let changes: [ConversationMarkChange] }
        struct Response: Decodable, Sendable { let delta: ConversationMarks? }
        let response: Response = try await callDecodable(
            method: "conversation/marks/update",
            params: encodeToJSONValue(Request(changes: changes)),
            timeout: timeouts.request
        )
        return response.delta
    }

    func resolveProjects(directories: [String]) async throws -> [ProjectIdentity] {
        struct Request: Encodable { let directories: [String] }
        struct Response: Decodable, Sendable { let projects: [ProjectIdentity] }
        let response: Response = try await callDecodable(
            method: "conversation/projects/resolve",
            params: encodeToJSONValue(Request(directories: directories)),
            timeout: timeouts.request
        )
        return response.projects
    }
}
