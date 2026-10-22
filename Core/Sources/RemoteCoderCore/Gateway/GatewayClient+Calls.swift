import Foundation

extension GatewayClient {
    func readThreadForIncomingCall(threadID: String) async throws -> CodexAppServerV2.ThreadReadResponse {
        let params = CodexAppServerV2.ThreadReadParams(threadId: threadID, includeTurns: false)
        return try await callDecodable(
            method: "thread/read",
            params: encodeToJSONValue(params),
            timeout: .seconds(2)
        )
    }

    func listRealtimeVoices() async throws -> [String] {
        let response: RealtimeVoiceListResponse = try await callDecodable(
            method: "voice/listVoices",
            params: encodeToJSONValue(RealtimeVoiceListRequest()),
            timeout: timeouts.request
        )
        return response.voices
    }

    func incomingCallStatus(callID: UUID) async throws -> AgentCallStatus {
        try await callDecodable(method: "calls/status",
            params: encodeToJSONValue(GatewayRequestParams.Call(callId: callID.uuidString.lowercased())), timeout: timeouts.request)
    }

    func reportIncomingCallRinging(callID: UUID, deviceID: String) async throws {
        _ = try await call(method: "calls/ringing",
            params: encodeToJSONValue(GatewayRequestParams.CallRinging(callId: callID.uuidString.lowercased(), deviceId: deviceID)),
            timeout: timeouts.request)
    }

    func answerIncomingCall(
        callID: UUID, deviceID: String, sdp: String, voice: String?
    ) async throws -> RealtimeVoiceStartResponse {
        let id = callID.uuidString.lowercased()
        return try await callDecodable(
            method: "calls/answer",
            params: encodeToJSONValue(GatewayRequestParams.CallAnswer(
                callId: id, deviceId: deviceID, realtimeSessionId: id, sdp: sdp, voice: voice)),
            timeout: timeouts.realtimeSetup
        )
    }

    func reportIncomingCallConnected(callID: UUID, deviceID: String) async throws {
        let id = callID.uuidString.lowercased()
        _ = try await call(method: "calls/connected",
            params: encodeToJSONValue(GatewayRequestParams.CallConnected(callId: id, deviceId: deviceID, realtimeSessionId: id)),
            timeout: timeouts.request)
    }

    func endIncomingCall(callID: UUID, deviceID: String, reason: String) async throws {
        _ = try await call(method: "calls/end",
            params: encodeToJSONValue(GatewayRequestParams.CallEnd(callId: callID.uuidString.lowercased(), deviceId: deviceID, reason: reason)),
            timeout: timeouts.request)
    }

    func startRealtimeVoiceSession(
        conversationThreadID: String,
        realtimeSessionID: String,
        replaceExistingSession: Bool,
        model: String,
        effort: String?,
        cwd: String,
        sdp: String,
        voice: String?,
        initialItems: [RealtimeVoiceInitialItem]
    ) async throws -> RealtimeVoiceStartResponse {
        try Task.checkCancellation()
        let request = RealtimeVoiceStartRequest(
            conversationThreadID: conversationThreadID,
            realtimeSessionID: realtimeSessionID,
            replaceExistingSession: replaceExistingSession,
            cwd: cwd,
            model: model,
            effort: effort,
            sdp: sdp,
            voice: voice,
            initialItems: initialItems
        )
        let response: RealtimeVoiceStartResponse = try await callDecodable(
            method: "voice/session/start",
            params: encodeToJSONValue(request),
            timeout: timeouts.realtimeSetup
        )
        return response
    }

    func reportVoiceSessionConnected(realtimeSessionID: String) async throws {
        _ = try await call(method: "voice/session/connected",
            params: encodeToJSONValue(GatewayRequestParams.VoiceSessionConnected(realtimeSessionId: realtimeSessionID)),
            timeout: timeouts.request)
    }

    func stopRealtimeVoiceSession() async throws {
        let _: RealtimeVoiceStopResponse = try await callDecodable(
            method: "voice/session/stop",
            params: encodeToJSONValue(RealtimeVoiceStopRequest()),
            timeout: timeouts.request
        )
    }
}
