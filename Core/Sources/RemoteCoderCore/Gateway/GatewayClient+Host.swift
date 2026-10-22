import Foundation

extension GatewayClient {
    struct HostInfoResponse: Decodable, Sendable {
        let homeDirectory: String
        var hostname: String? = nil
        var automationsAuthority: String? = nil
        var speechAvailable: Bool? = nil
    }

    func registerDevice(_ request: DeviceRegistrationRequest) async throws -> DeviceRegistrationResponse {
        try await callDecodable(
            method: "devices/register",
            params: encodeToJSONValue(request),
            timeout: timeouts.request
        )
    }

    func unregisterDevice(deviceID: String) async throws {
        _ = try await call(
            method: "devices/unregister",
            params: encodeToJSONValue(GatewayRequestParams.Device(deviceId: deviceID)),
            timeout: timeouts.request
        )
    }

    func readHostInfo() async throws -> HostInfoResponse {
        try await callDecodable(method: "host/info", params: encodeToJSONValue(GatewayRequestParams.Empty()), timeout: timeouts.request)
    }

    func readActiveTurns() async throws -> CodexGatewayDaemon.ActiveTurnsResponse {
        try await callDecodable(method: "daemon/activeTurns", params: encodeToJSONValue(GatewayRequestParams.Empty()), timeout: timeouts.request)
    }

    func readLiveActivity() async throws -> ActiveTasksLiveActivitySnapshot? {
        try await callDecodable(method: "daemon/liveActivity", params: encodeToJSONValue(GatewayRequestParams.Empty()), timeout: timeouts.request)
    }

    func takeOverConversation(threadID: String) async throws {
        _ = try await call(
            method: "conversation/takeOver",
            params: encodeToJSONValue(GatewayRequestParams.ThreadReference(threadId: threadID)),
            timeout: timeouts.threadSetup
        )
    }

    func regenerateTitle(threadID: String) async throws {
        _ = try await call(
            method: "conversation/title/regenerate",
            params: encodeToJSONValue(GatewayRequestParams.ThreadReference(threadId: threadID)),
            timeout: timeouts.threadSetup
        )
    }

    func execCommand(
        command: [String],
        cwd: String? = nil
    ) async throws -> CodexAppServerV2.CommandExecResponse {
        precondition(!command.isEmpty, "command/exec requires a non-empty command")
        let params = CodexAppServerV2.CommandExecParams(
            command: command,
            cwd: cwd
        )
        return try await callDecodable(
            method: "command/exec",
            params: encodeToJSONValue(params),
            timeout: timeouts.commandExec
        )
    }

    func readDirectory(path: String) async throws -> CodexAppServerV2.FsReadDirectoryResponse {
        let params = CodexAppServerV2.FsReadDirectoryParams(path: path)
        return try await callDecodable(
            method: "fs/readDirectory",
            params: encodeToJSONValue(params),
            timeout: timeouts.request
        )
    }

    func listModels(cursor: String?) async throws -> CodexAppServerV2.ModelListResponse {
        let params = CodexAppServerV2.ModelListParams(cursor: cursor)
        return try await callDecodable(
            method: "model/list",
            params: encodeToJSONValue(params),
            timeout: timeouts.request
        )
    }
}

extension GatewayClient: DeviceRegistrationTransport {}
