import Foundation

extension GatewayClient: ConversationMetadataRemote {
    func fetchRemoteMetadata(knownRevision: String?) async throws -> ConversationMetadataSnapshot {
        struct Request: Encodable { let knownRevision: String? }
        let data = try await callRaw(method: "conversation/metadata/read",
            params: encodeToJSONValue(Request(knownRevision: knownRevision)), timeout: timeouts.request)
        return try await GatewayFrameDecoder.decodeResult(ConversationMetadataSnapshot.self, from: data,
            dateDecodingStrategy: .deferredToDate)
    }

    func updateRemoteMetadata(_ mutation: ConversationMetadataMutation) async throws -> ConversationMetadata {
        let data = try await callRaw(method: "conversation/metadata/update", params: encodeToJSONValue(mutation), timeout: timeouts.request)
        let result = try await GatewayFrameDecoder.decodeResult(ConversationMetadataRecord.self, from: data, dateDecodingStrategy: .deferredToDate)
        guard result.sessionID == mutation.selection.sessionID,
              ConversationMetadata(result).selection == mutation.selection,
              result.mutationID == mutation.mutationID, (result.serverRevision ?? 0) > 0 else { throw ClientError.invalidMessage }
        return ConversationMetadata(result)
    }
}

extension GatewayClient: QuestionRemote {
    func readQuestions(_ queries: [QuestionReadQuery]) async throws -> [QuestionHostSnapshot] {
        struct Request: Encodable { let queries: [QuestionReadQuery] }
        struct Response: Decodable, Sendable { let threads: [QuestionHostSnapshot] }
        let response: Response = try await callDecodable(method: "conversation/questions/read",
            params: encodeToJSONValue(Request(queries: queries)), timeout: timeouts.request)
        guard Set(response.threads.map(\.threadId)) == Set(queries.map(\.threadId)), response.threads.count == queries.count
        else { throw ClientError.invalidMessage }
        for snapshot in response.threads { try snapshot.validate() }
        return response.threads
    }

    func dismissQuestion(_ request: QuestionDismissal) async throws -> QuestionDismissalResult {
        let response: QuestionDismissalResult = try await callDecodable(method: "conversation/question/dismiss",
            params: encodeToJSONValue(request), timeout: timeouts.request)
        guard response.record.itemId == request.itemId, response.record.revision <= response.revision, !response.epoch.isEmpty
        else { throw ClientError.invalidMessage }
        return response
    }
}
