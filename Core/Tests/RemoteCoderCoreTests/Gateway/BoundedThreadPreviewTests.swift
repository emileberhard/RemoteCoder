import Foundation
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct BoundedThreadPreviewTests {
    @Test(arguments: ["thread/list", "claude/thread/list"], [false, true])
    func nativeHistoryOptsInAndDecodesBoundedOrOlderFullPreviews(_ method: String, _ bounded: Bool) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let prefix = String(repeating: "👩🏽‍💻e\u{301}", count: 1_024)
        let preview = prefix + (bounded ? "" : "older gateway tail")
        let id = method == "thread/list" ? "native" : "claude_session"
        await fixture.setResult(.object([
            "data": .array([.object([
                "id": .string(id), "preview": .string(preview), "createdAt": .number(1),
                "updatedAt": .number(2), "cwd": .string("/repo"), "source": .string("cli")
            ])]),
            "nextCursor": .string("next"),
            "completionTimes": .object([id: .number(3)])
        ]), method: method)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            let response = try await (method == "thread/list"
                ? gateway.listThreads(limit: 60, cursor: "cursor", useStateDBOnly: true)
                : gateway.listClaudeThreads(limit: 60, cursor: "cursor"))
            let request = try #require(await fixture.recordedRequests.first { $0.method == method })
            let params = try #require(request.params?.objectValue)
            #expect(params["boundedPreview"] == .bool(true))
            #expect(params["limit"] == .number(60))
            #expect(params["cursor"] == .string("cursor"))
            if method == "thread/list" {
                #expect(params["useStateDbOnly"] == .bool(true))
                #expect(params["includeCompletionTimes"] == .bool(true))
            }
            let thread = try #require(response.data.first)
            #expect(thread.preview == preview)
            #expect(ConversationHeader(thread).preview == String(prefix.prefix(512)))
            #expect(response.nextCursor == "next")
            #expect(response.completionTimes?[id] == 3)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }
}
