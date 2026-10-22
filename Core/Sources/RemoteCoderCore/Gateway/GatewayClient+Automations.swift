import Foundation

extension GatewayClient {
    func automationStatus() async throws -> AutomationEnvelope<AutomationStatus> {
        try await automationCall("status", request: AutomationRequest())
    }
    func listAutomations(_ request: AutomationRequest) async throws -> AutomationEnvelope<AutomationList> {
        try await automationCall("list", request: request)
    }
    func showAutomation(_ request: AutomationRequest) async throws -> AutomationEnvelope<AutomationDetail> {
        try await automationCall("show", request: request)
    }
    func showAutomationReceipt(_ requestID: String) async throws -> JSONValue {
        let result: AutomationEnvelope<JSONValue> = try await automationCall("show", request: AutomationRequest(id: "request/\(requestID)"))
        return try result.value()
    }
    func automationHistory(_ request: AutomationRequest) async throws -> AutomationEnvelope<AutomationHistory> {
        try await automationCall("history", request: request)
    }
    func automationRunDetail(_ request: AutomationRequest) async throws -> AutomationEnvelope<AutomationRunDetail> {
        try await automationCall("show", request: request)
    }
    func setAutomation(_ request: AutomationRequest) async throws -> AutomationEnvelope<JSONValue> {
        try await automationCall("set", request: request)
    }
    func removeAutomation(_ request: AutomationRequest) async throws -> AutomationEnvelope<JSONValue> {
        try await automationCall("remove", request: request)
    }
    func restoreAutomation(_ request: AutomationRequest) async throws -> AutomationEnvelope<JSONValue> {
        try await automationCall("restore", request: request)
    }
    func runAutomation(_ request: AutomationRequest) async throws -> AutomationEnvelope<JSONValue> {
        try await automationCall("run", request: request)
    }
    private func automationCall<T: Decodable & Sendable>(
        _ operation: String, request: AutomationRequest
    ) async throws -> AutomationEnvelope<T> {
        let timeout: Duration = ["set", "restore", "run"].contains(operation) ? .seconds(310) : .seconds(25)
        return try await callDecodable(method: "automations/\(operation)", params: encodeToJSONValue(request), timeout: timeout)
    }
}
