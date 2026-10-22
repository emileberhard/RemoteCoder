import Foundation

struct AgentCallFailure: Encodable, Equatable, Sendable {
    let domain: String
    let code: Int
    let reason: String
}

struct AgentCallDiagnostic: Encodable, Sendable {
    let recordType = "agentCall"
    let ts: Date
    let uptime: TimeInterval
    let processID: Int32
    let callId: UUID?
    let hostId: UUID?
    let stage: String
    let detail: String
    let failure: AgentCallFailure?

    func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(DiagnosticsOutbox.timestampStyle))
        }
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
