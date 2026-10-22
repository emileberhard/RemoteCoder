import Foundation

protocol CodexHistoryGateway: Actor {
    var historyHostID: String { get }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) async throws -> CodexAppServerV2.ThreadListResponse
    func listClaudeThreads(limit: Int, cursor: String?) async throws -> CodexAppServerV2.ThreadListResponse
    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexAppServerV2.ThreadReadResponse
    func historyPageData(method: String, params: JSONValue) async throws -> Data
}
