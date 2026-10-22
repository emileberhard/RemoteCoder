import Foundation
@testable import RemoteCoderCore

extension ConversationSession {
    static func make(conversationID: UUID, threadID: String? = nil, checkpoints: ConversationCheckpointStore) async -> ConversationSession {
        let generation = await checkpoints.generation(for: conversationID)
        return ConversationSession(conversationID: conversationID, threadID: threadID, checkpoints: checkpoints,
            checkpointGeneration: generation)
    }

    @discardableResult
    func submitDurably(_ message: ChatMessage, input: String? = nil,
                       expectedQuestionVersion: QuestionVersion? = nil) async throws -> ConversationSnapshot {
        let snapshot = try await submit(message, input: input, expectedQuestionVersion: expectedQuestionVersion)
        try await persistSubmission(message.id)
        return snapshot
    }
}
