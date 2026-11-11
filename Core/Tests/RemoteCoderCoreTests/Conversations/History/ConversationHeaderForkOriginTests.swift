import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationHeaderForkOriginTests {
    @Test func aReadNamesTheSourceAndTheHeaderCacheKeepsIt() throws {
        let fork = try ThreadFixture.basic("claude_fork", updatedAt: 2, fields: ["forkedFromId": "claude_source"])
        #expect(fork.forkedFromThreadID == "claude_source")
        let cached = try JSONDecoder().decode(ConversationHeader.self, from: JSONEncoder().encode(fork))
        #expect(cached.forkedFromThreadID == "claude_source")
        #expect(try ThreadFixture.basic("claude_source", updatedAt: 1).forkedFromThreadID == nil)
    }

    @Test func aListRowWithoutTheFieldKeepsAKnownSourceAndInventsNone() throws {
        let read = try ThreadFixture.basic("fork", updatedAt: 2, fields: ["forkedFromId": "source"])
        var row = try ThreadFixture.basic("fork", updatedAt: 3)
        row.retainAncestry(from: read)
        #expect(row.forkedFromThreadID == "source")
        var unknown = try ThreadFixture.basic("fork", updatedAt: 3)
        unknown.retainAncestry(from: try ThreadFixture.basic("fork", updatedAt: 2))
        #expect(unknown.forkedFromThreadID == nil)
    }
}
