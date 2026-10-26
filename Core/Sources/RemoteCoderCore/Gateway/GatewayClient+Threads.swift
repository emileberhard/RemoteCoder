import Foundation

extension GatewayClient {
    // These callers consume only the thread. Claude may have no recorded model
    // yet, so decoding unused top-level resume defaults would reject a valid header.
    private struct ThreadResponse: Decodable, Sendable {
        let thread: CodexAppServerV2.Thread
    }

    private struct ThreadStartResponse: Decodable, Sendable {
        let thread: CodexAppServerV2.Thread
        let model: String?
        let reasoningEffort: CodexAppServerV2.ReasoningEffort?
    }

    func startOrResumeThread(
        threadID: String?,
        model: String,
        cwd: String?,
        serviceTier: CodexAppServerV2.ServiceTierOverride?,
        provider: AgentProvider = .codex,
        serviceName: String = "RemoteCoder",
        effort: String? = nil
    ) async throws -> CodexAppServerV2.Thread {
        guard let threadID else {
            return try await startThread(model: model, cwd: cwd, serviceTier: serviceTier, provider: provider,
                                         serviceName: serviceName, config: effort.flatMap(CodexAppServerV2.ReasoningEffort.init(rawValue:))
                    .map { .init(modelReasoningEffort: $0) })
        }
        let params = CodexAppServerV2.ThreadResumeParams(
            threadId: threadID,
            model: model,
            cwd: cwd,
            approvalPolicy: DispatchPolicy.approvalPolicy,
            sandbox: DispatchPolicy.threadSandbox,
            serviceTier: serviceTier
        )
        let response: ThreadResponse = try await callDecodable(
            method: "thread/resume",
            params: encodeToJSONValue(params),
            timeout: timeouts.threadSetup
        )
        return response.thread
    }

    func startThread(
        model: String,
        cwd: String?,
        serviceTier: CodexAppServerV2.ServiceTierOverride?,
        provider: AgentProvider,
        serviceName: String,
        config: CodexAppServerV2.ThreadStartConfig?
    ) async throws -> CodexAppServerV2.Thread {
        let params = CodexAppServerV2.ThreadStartParams(
            model: model,
            cwd: cwd,
            approvalPolicy: DispatchPolicy.approvalPolicy,
            sandbox: DispatchPolicy.threadSandbox,
            serviceName: serviceName,
            serviceTier: serviceTier,
            config: config
        )
        let response: ThreadStartResponse = try await callDecodable(
            method: "thread/start",
            params: try threadStartPayload(provider: provider, serviceName: serviceName, params: encodeToJSONValue(params)),
            timeout: timeouts.threadSetup
        )
        var thread = response.thread
        if thread.model == nil { thread.model = response.model }
        if thread.reasoningEffort == nil { thread.reasoningEffort = response.reasoningEffort }
        return thread
    }

    /// Gateway routing fields are injected outside the upstream wire models.
    /// Only a new thread needs them: afterwards the gateway routes by thread id.
    private func threadStartPayload(provider: AgentProvider, serviceName: String, params: JSONValue) -> JSONValue {
        guard case .object(var fields) = params else { return params }
        if provider != .codex { fields["provider"] = .string(provider.rawValue) }
        if serviceName != "RemoteCoder Voice" { fields["acceptProviderFallback"] = .bool(true) }
        return .object(fields)
    }

    func resumeThreadPreservingSettings(threadID: String) async throws -> CodexAppServerV2.Thread {
        let response: ThreadResponse = try await callDecodable(
            method: "thread/resume",
            params: encodeToJSONValue(GatewayRequestParams.ThreadResume(threadId: threadID, excludeTurns: true)),
            timeout: timeouts.threadSetup
        )
        return response.thread
    }

    struct CompactionPreparationFailure: LocalizedError {
        let underlying: any Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// Acknowledgment admits the operation; canonical compaction items confirm completion.
    func compactThread(threadID: String, provider: AgentProvider) async throws {
        do {
            try Task.checkCancellation()
            if provider == .codex { _ = try await resumeThreadPreservingSettings(threadID: threadID) }
            try Task.checkCancellation()
        } catch { throw CompactionPreparationFailure(underlying: error) }
        struct Acknowledgment: Decodable, Sendable {}
        let _: Acknowledgment = try await callDecodable(
            method: "thread/compact/start",
            params: .object(["threadId": .string(threadID)]),
            timeout: timeouts.threadSetup
        )
    }

    func listClaudeThreads(limit: Int, cursor: String?) async throws -> CodexAppServerV2.ThreadListResponse {
        struct Params: Encodable {
            let limit: Int
            let cursor: String?
        }
        return try await callDecodable(
            method: "claude/thread/list",
            params: boundedThreadListPayload(encodeToJSONValue(Params(limit: limit, cursor: cursor))),
            timeout: timeouts.history
        )
    }

    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexAppServerV2.ThreadReadResponse {
        let params = CodexAppServerV2.ThreadReadParams(threadId: threadID, includeTurns: includeTurns)
        return try await callDecodable(
            method: "thread/read",
            params: encodeToJSONValue(params),
            timeout: timeouts.history
        )
    }

    func updateConversationSettings(_ settings: ConversationSettingsUpdate) async throws -> ConversationSettingsUpdateResponse {
        try await callDecodable(
            method: "conversation/settings/update",
            params: encodeToJSONValue(settings),
            timeout: .seconds(90)
        )
    }

    func replayNotifications(
        afterSequence: UInt64,
        epoch: String?,
        threadID: String? = nil,
        limit: Int? = nil
    ) async throws -> CodexGatewayDaemon.ReplayNotificationsResponse {
        if let limit { precondition(limit > 0, "daemon/replayNotifications limit requires limit > 0") }
        return try await callDecodable(
            method: "daemon/replayNotifications",
            params: encodeToJSONValue(GatewayRequestParams.ReplayNotifications(
                afterSequence: afterSequence, epoch: epoch, threadId: threadID, limit: limit)),
            timeout: timeouts.request
        )
    }

    func replayThreadNotifications(
        afterSequence: UInt64,
        epoch: String?,
        threadID: String,
        limit: Int? = nil
    ) async throws -> CodexGatewayDaemon.ReplayNotificationsResponse {
        if let limit { precondition(limit > 0, "daemon/replayNotifications limit requires limit > 0") }
        return try await callDecodable(
            method: "daemon/replayNotifications",
            params: encodeToJSONValue(GatewayRequestParams.ReplayNotifications(
                afterSequence: afterSequence, epoch: epoch, threadId: threadID, limit: limit)),
            timeout: timeouts.request
        )
    }

    func listThreads(
        limit: Int,
        cursor: String? = nil,
        useStateDBOnly: Bool = false
    ) async throws -> CodexAppServerV2.ThreadListResponse {
        precondition(limit > 0, "thread/list requires limit > 0")
        let params = CodexAppServerV2.ThreadListParams(
            cursor: cursor,
            limit: UInt32(limit),
            useStateDbOnly: useStateDBOnly
        )
        return try await callDecodable(method: "thread/list", params: boundedThreadListPayload(encodeToJSONValue(params)), timeout: timeouts.history)
    }

    private func boundedThreadListPayload(_ params: JSONValue) -> JSONValue {
        guard case .object(var fields) = params else { preconditionFailure("Thread list parameters must be an object") }
        fields["boundedPreview"] = .bool(true)
        return .object(fields)
    }

    func forkThread(
        threadID: String,
        lastTurnID: String? = nil,
        serviceTier: CodexAppServerV2.ServiceTierOverride? = nil
    ) async throws -> CodexAppServerV2.ThreadForkResponse {
        let params = CodexAppServerV2.ThreadForkParams(
            threadId: threadID,
            lastTurnId: lastTurnID,
            serviceTier: serviceTier
        )
        return try await callDecodable(
            method: "thread/fork",
            params: encodeToJSONValue(params),
            timeout: timeouts.threadSetup
        )
    }

    func startTurn(
        threadID: String,
        clientUserMessageID: String,
        input: String,
        model: String,
        cyberAccessProgram: CodexAppServerV2.CyberAccessProgram?,
        effort: String?,
        cwd: String?,
        serviceTier: CodexAppServerV2.ServiceTierOverride?,
        additionalContext: [String: CodexAppServerV2.AdditionalContextEntry]? = nil
    ) async throws -> String {
        try await connectIfNeeded()

        let userInput = try buildUserInput(text: input)

        let params = CodexAppServerV2.TurnStartParams(
            threadId: threadID,
            input: userInput,
            cwd: cwd,
            approvalPolicy: DispatchPolicy.approvalPolicy,
            sandboxPolicy: DispatchPolicy.turnSandbox,
            model: model,
            cyberAccessProgram: cyberAccessProgram,
            effort: effort.flatMap(CodexAppServerV2.ReasoningEffort.init(rawValue:)),
            serviceTier: serviceTier,
            additionalContext: additionalContext,
            clientUserMessageId: clientUserMessageID
        )
        let response: CodexAppServerV2.TurnStartResponse = try await callDecodable(
            method: "turn/start",
            params: encodeToJSONValue(params),
            timeout: timeouts.request
        )

        return response.turn.id
    }

    func steerTurn(
        threadID: String,
        expectedTurnID: String,
        clientUserMessageID: String,
        input: String,
        additionalContext: [String: CodexAppServerV2.AdditionalContextEntry]? = nil
    ) async throws -> String {
        guard !expectedTurnID.isEmpty else { throw ClientError.invalidMessage }

        let userInput = try buildUserInput(text: input)

        let params = CodexAppServerV2.TurnSteerParams(
            threadId: threadID,
            input: userInput,
            expectedTurnId: expectedTurnID,
            additionalContext: additionalContext,
            clientUserMessageId: clientUserMessageID
        )
        let response: CodexAppServerV2.TurnSteerResponse = try await callDecodable(
            method: "turn/steer",
            params: encodeToJSONValue(params),
            timeout: timeouts.request
        )
        return response.turnId
    }

    func queueMessage(
        threadID: String,
        clientUserMessageID: String,
        input: String
    ) async throws -> CodexAppServerV2.QueuedSubmission {
        let userInput = try buildUserInput(text: input)
        let params = CodexAppServerV2.ThreadQueueAddParams(
            threadId: threadID, input: userInput, clientUserMessageId: clientUserMessageID)
        let response: CodexAppServerV2.ThreadQueueAddResponse = try await callDecodable(
            method: "thread/queue/add", params: encodeToJSONValue(params), timeout: timeouts.request)
        guard response.queuedSubmission.clientUserMessageId == clientUserMessageID else { throw ClientError.invalidMessage }
        return response.queuedSubmission
    }

    func queuedMessages(threadID: String) async throws -> [CodexAppServerV2.QueuedSubmission] {
        var submissions: [CodexAppServerV2.QueuedSubmission] = []
        var cursor: String?
        for _ in 0..<Self.queuePageLimit {
            let response: CodexAppServerV2.ThreadQueueListResponse = try await callDecodable(
                method: "thread/queue/list",
                params: encodeToJSONValue(CodexAppServerV2.ThreadQueueListParams(threadId: threadID, cursor: cursor)),
                timeout: timeouts.request)
            submissions += response.data
            guard let next = response.nextCursor else { return submissions }
            cursor = next
        }
        throw ClientError.invalidMessage
    }

    func startQueuedMessage(threadID: String, queuedSubmissionID: String) async throws -> String {
        let response: CodexAppServerV2.ThreadQueueStartResponse = try await callDecodable(
            method: "thread/queue/start",
            params: encodeToJSONValue(CodexAppServerV2.ThreadQueueItemParams(
                threadId: threadID, queuedSubmissionId: queuedSubmissionID)),
            timeout: timeouts.request)
        return response.turn.id
    }

    func deleteQueuedMessage(threadID: String, queuedSubmissionID: String) async throws -> Bool {
        let response: CodexAppServerV2.ThreadQueueDeleteResponse = try await callDecodable(
            method: "thread/queue/delete",
            params: encodeToJSONValue(CodexAppServerV2.ThreadQueueItemParams(
                threadId: threadID, queuedSubmissionId: queuedSubmissionID)),
            timeout: timeouts.request)
        return response.deleted
    }

    private static let queuePageLimit = 8

    func conversationAgents(threadID: String) async throws -> ConversationAgentsPage {
        try await callDecodable(method: "conversation/agents/list", params: encodeToJSONValue(GatewayRequestParams.ThreadReference(threadId: threadID)), timeout: timeouts.history)
    }

    func agentOutput(threadID: String, agentID: String) async throws -> ConversationAgentOutput {
        try await callDecodable(method: "conversation/agents/read",
            params: encodeToJSONValue(GatewayRequestParams.AgentRead(threadId: threadID, agentId: agentID)), timeout: timeouts.history)
    }

    func agentAction(threadID: String, agent: ConversationAgent, action: ConversationAgentAction, text: String, mutationID: UUID) async throws {
        let _: JSONValue = try await callDecodable(
            method: "conversation/agents/action",
            params: encodeToJSONValue(GatewayRequestParams.AgentAction(
                threadId: threadID, agentId: agent.id, executionId: agent.executionId,
                action: action.rawValue, text: text, mutationId: mutationID.uuidString)),
            timeout: timeouts.history)
    }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        precondition(["thread/turns/list", "thread/items/list", "conversation/agents/classify"].contains(method))
        return try await callRaw(method: method, params: params, timeout: timeouts.history)
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        guard !threadID.isEmpty else { throw ClientError.invalidMessage }
        guard !turnID.isEmpty else { throw ClientError.invalidMessage }

        let params = CodexAppServerV2.TurnInterruptParams(threadId: threadID, turnId: turnID)
        let _: CodexAppServerV2.TurnInterruptResponse = try await callDecodable(
            method: "turn/interrupt",
            params: encodeToJSONValue(params),
            timeout: timeouts.request
        )
    }

    private func buildUserInput(text: String) throws -> [CodexAppServerV2.UserInput] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.invalidMessage }
        return [.text(text: trimmed, textElements: [])]
    }
}

extension GatewayClient: TurnInterrupting {}
