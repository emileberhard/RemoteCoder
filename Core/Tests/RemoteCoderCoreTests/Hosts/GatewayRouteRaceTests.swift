import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct GatewayRouteRaceTests {
    private struct Refused: Error {}

    private final class Attempts: Sendable {
        let started = Mutex<[String]>([])
        let cancelled = Mutex<[String]>([])
        let discarded = Mutex<[String]>([])
    }

    private func race(_ candidates: [(String, Duration)], attempts: Attempts,
                      attempt: @escaping @Sendable (String) async throws -> String) async -> GatewayRouteRace<String, String>.Outcome {
        await GatewayRouteRace(
            candidates: candidates.map { (route: $0.0, headStart: $0.1) },
            attempt: { route in
                attempts.started.withLock { $0.append(route) }
                return try await attempt(route)
            },
            discard: { connection in attempts.discarded.withLock { $0.append(connection) } }
        ).run()
    }

    @Test func aSilentRouteYieldsToTheNextOnceItsHeadStartElapses() async {
        let attempts = Attempts()
        let started = ContinuousClock.now
        let outcome = await race([("tailscale", .milliseconds(200)), ("relay", .seconds(30))], attempts: attempts) { route in
            if route == "tailscale" {
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    attempts.cancelled.withLock { $0.append(route) }
                    throw error
                }
            }
            return route
        }
        let elapsed = started.duration(to: .now)
        #expect(outcome.winner?.route == "relay")
        #expect(outcome.failures.isEmpty)
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(10))
        #expect(attempts.started.withLock { $0 } == ["tailscale", "relay"])
        #expect(attempts.cancelled.withLock { $0 } == ["tailscale"])
    }

    @Test func aRefusedRouteStartsTheNextAtOnce() async {
        let attempts = Attempts()
        let started = ContinuousClock.now
        let outcome = await race([("tailscale", .seconds(30)), ("relay", .seconds(30))], attempts: attempts) { route in
            if route == "tailscale" { throw Refused() }
            return route
        }
        #expect(outcome.winner?.route == "relay")
        #expect(outcome.failures.map(\.route) == ["tailscale"])
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func aPreferredRouteThatAnswersWithinItsHeadStartIsTheOnlyAttempt() async {
        let attempts = Attempts()
        let outcome = await race([("lan", .seconds(30)), ("tailscale", .seconds(30)), ("relay", .seconds(30))],
                                 attempts: attempts) { $0 }
        #expect(outcome.winner?.route == "lan")
        #expect(attempts.started.withLock { $0 } == ["lan"])
    }

    @Test func aRouteThatSucceedsAfterAnotherWonIsDiscarded() async {
        let attempts = Attempts()
        let outcome = await race([("tailscale", .milliseconds(100)), ("relay", .seconds(30))], attempts: attempts) { route in
            if route == "tailscale" { try? await Task.sleep(for: .seconds(60)) }
            return route
        }
        #expect(outcome.winner?.route == "relay")
        #expect(attempts.discarded.withLock { $0 } == ["tailscale"])
    }

    @Test func everyRouteFailingReportsEachFailureInTheOrderTheyFailed() async {
        let attempts = Attempts()
        let started = ContinuousClock.now
        let outcome = await race([("tailscale", .seconds(30)), ("relay", .seconds(30))], attempts: attempts) { _ in
            throw Refused()
        }
        #expect(outcome.winner == nil)
        #expect(outcome.failures.map(\.route) == ["tailscale", "relay"])
        #expect(started.duration(to: .now) < .seconds(10))
    }
}
