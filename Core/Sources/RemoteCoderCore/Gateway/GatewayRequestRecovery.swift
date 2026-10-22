import Foundation

nonisolated enum GatewayRequestRecovery {
    static func run<Value: Sendable>(method: String, timeout: Duration,
        operation: @Sendable (Duration) async throws -> Value) async throws -> Value {
        let deadline = ContinuousClock.now + timeout
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw GatewayClient.ClientError.requestTimedOut(method: method) }
                let value = try await operation(remaining)
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                guard retries < 3,
                      let failure = error as? GatewayRPCFailure, failure.kind == .capacity, failure.retryable else { throw error }
                let delay = Duration.milliseconds(Double(100 << retries) * Double.random(in: 0.8...1.2))
                guard ContinuousClock.now + delay < deadline else { throw error }
                retries += 1
                try await Task.sleep(for: delay)
                guard ContinuousClock.now < deadline else { throw error }
            }
        }
    }
}
