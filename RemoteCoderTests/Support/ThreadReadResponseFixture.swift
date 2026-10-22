import Foundation
@testable import RemoteCoder

extension CodexAppServerV2.ThreadReadResponse {
    init(_ header: ConversationHeader) {
        self.init(thread: .init(
            id: header.id, preview: header.preview, model: header.model, reasoningEffort: header.reasoningEffort,
            extra: header.extra, createdAt: header.createdAt, updatedAt: header.updatedAt,
            lastTurnCompletedAt: header.lastTurnCompletedAt, path: header.path, cwd: header.cwd,
            source: .string("appServer"), name: header.name, status: header.status,
            parentThreadId: header.nativeParentThreadID, canAcceptDirectInput: header.canAcceptDirectInput,
            agentRelation: header.agentRelation))
    }
}
