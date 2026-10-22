import Foundation

struct PendingGatewayRequest {
    enum Completion {
        case json(CheckedContinuation<JSONValue, Error>)
        case raw(CheckedContinuation<Data, Error>)
        case observed(CheckedContinuation<(Data, GatewayWireReceipt), Error>)
    }
    let completion: Completion
    var wantsRaw: Bool {
        switch completion {
        case .raw, .observed: true
        case .json: false
        }
    }
    func fail(_ error: Error) {
        switch completion {
        case .json(let continuation): continuation.resume(throwing: error)
        case .raw(let continuation): continuation.resume(throwing: error)
        case .observed(let continuation): continuation.resume(throwing: error)
        }
    }
    func succeed(_ value: JSONValue, raw: Data, receipt: GatewayWireReceipt) {
        switch completion {
        case .json(let continuation): continuation.resume(returning: value)
        case .raw(let continuation): continuation.resume(returning: raw)
        case .observed(let continuation): continuation.resume(returning: (raw, receipt))
        }
    }
    func succeed(raw: Data, receipt: GatewayWireReceipt) {
        switch completion {
        case .raw(let continuation): continuation.resume(returning: raw)
        case .observed(let continuation): continuation.resume(returning: (raw, receipt))
        case .json: preconditionFailure("Unexpected raw response")
        }
    }
    let timeoutTask: Task<Void, Never>
    let method: String
    let startedAt: ContinuousClock.Instant
}

struct RequestTable {
    private var requests: [Int64: PendingGatewayRequest] = [:]
    private var nextID: Int64 = 1

    var isEmpty: Bool { requests.isEmpty }
    var count: Int { requests.count }
    var rawResponseIDs: Set<Int64> { Set(requests.filter { $0.value.wantsRaw }.keys) }

    mutating func allocateID() -> Int64 { defer { nextID += 1 }; return nextID }
    mutating func insert(_ request: PendingGatewayRequest, id: Int64) { requests[id] = request }
    mutating func remove(id: Int64) -> PendingGatewayRequest? { requests.removeValue(forKey: id) }
    mutating func removeAll() -> [PendingGatewayRequest] { defer { requests.removeAll() }; return Array(requests.values) }
}
