import Foundation

/// Polls a main-actor condition instead of sleeping a fixed amount.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async throws -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}
