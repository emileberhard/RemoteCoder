import Foundation

nonisolated enum PollingFailure: Error { case timedOut }

nonisolated func eventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw PollingFailure.timedOut
}
