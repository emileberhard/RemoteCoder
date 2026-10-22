nonisolated struct HistoryTailRecovery: Sendable {
    enum Request: Equatable, Sendable { case reload, latest }

    private(set) var pending: Request?

    mutating func request(_ request: Request) {
        if pending != .latest { pending = request }
    }

    mutating func loaded() { pending = nil }

    mutating func reset() { pending = nil }
}
