import Foundation

nonisolated struct GatewayReconnectPolicy {
    private static let ceilings: [Duration] = [1, 2, 4, 8, 16, 32, 60].map { .seconds($0) }
    private static let restartCeilings: [Duration] = [1, 2, 4].map { .seconds($0) }
    private static let restartPhase = Duration.seconds(45)
    private static let stableConnection = Duration.seconds(30)
    private static let expediteInterval = Duration.seconds(5)

    private(set) var notBefore: ContinuousClock.Instant?
    private(set) var failures = 0
    private var connectedAt: ContinuousClock.Instant?
    private var expeditedAt: ContinuousClock.Instant?
    private let jitter: @Sendable () -> Double

    init(jitter: @escaping @Sendable () -> Double = { .random(in: 0.5...1) }) {
        self.jitter = jitter
    }

    func permits(at now: ContinuousClock.Instant) -> Bool {
        notBefore.map { $0 <= now } ?? true
    }

    @discardableResult
    mutating func failed(at now: ContinuousClock.Instant, restartingSince: ContinuousClock.Instant?) -> Duration {
        let restarting = restartingSince.map { $0.duration(to: now) < Self.restartPhase } ?? false
        let ladder = restarting ? Self.restartCeilings : Self.ceilings
        failures = min(failures + 1, ladder.count)
        let delay = ladder[failures - 1] * jitter()
        notBefore = now + delay
        return delay
    }

    mutating func connected(at now: ContinuousClock.Instant) {
        connectedAt = now
        notBefore = nil
    }

    mutating func disconnected(at now: ContinuousClock.Instant, restartingSince: ContinuousClock.Instant?) {
        guard let connectedAt else { return }
        self.connectedAt = nil
        if connectedAt.duration(to: now) >= Self.stableConnection {
            failures = 0
        } else {
            failed(at: now, restartingSince: restartingSince)
        }
    }

    mutating func expedite(at now: ContinuousClock.Instant) -> Bool {
        guard !permits(at: now), expeditedAt.map({ $0.duration(to: now) >= Self.expediteInterval }) ?? true else { return false }
        expeditedAt = now
        notBefore = nil
        return true
    }
}
