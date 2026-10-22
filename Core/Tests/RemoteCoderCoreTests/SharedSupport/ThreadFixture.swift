import Foundation
#if canImport(RemoteCoderCore)
@testable import RemoteCoderCore
#else
@testable import RemoteCoder
#endif

enum ThreadFixture {
    static func basic(_ id: String, updatedAt: Int64, preview: String = "Test", fields: [String: Any] = [:]) throws -> ConversationHeader {
        let base: [String: Any] = [
            "id": id, "preview": preview, "modelProvider": "test",
            "createdAt": 0, "updatedAt": updatedAt, "cwd": "/repo", "cliVersion": "test",
            "source": "appServer", "status": ["type": "notLoaded"], "ephemeral": false, "turns": [],
        ]
        return try decode(base.merging(fields) { _, new in new })
    }

    static func decode(_ fields: [String: Any]) throws -> ConversationHeader {
        ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONSerialization.data(withJSONObject: fields)))
    }
}
