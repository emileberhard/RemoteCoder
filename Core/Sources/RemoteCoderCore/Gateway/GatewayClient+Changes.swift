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

    func readNewestTurnID(threadID: String) async throws -> String? {
        struct Request: Encodable {
            let threadId: String
            let sortDirection: CodexAppServerV2.SortDirection
            let limit: Int
            let itemsView: String
        }
        struct Page: Decodable {
            struct Turn: Decodable {
                let id: String
            }

            let data: [Turn]
        }
        let page: Page = try await callDecodable(
            method: "thread/turns/list",
            params: encodeToJSONValue(Request(threadId: threadID, sortDirection: .desc, limit: 1, itemsView: "notLoaded")),
            timeout: timeouts.history
        )
        return page.data.first?.id
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
