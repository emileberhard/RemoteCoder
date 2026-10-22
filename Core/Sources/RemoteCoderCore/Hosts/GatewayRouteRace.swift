import Foundation

struct GatewayRouteRace<Route: Sendable, Connection: Sendable> {
    struct Outcome: Sendable {
        let winner: (route: Route, connection: Connection)?
        let failures: [(route: Route, error: any Error)]
    }

    private enum Event: Sendable {
        case finished(Int, Result<Connection, any Error>)
        case headStartElapsed(Int)
    }

    let candidates: [(route: Route, headStart: Duration)]
    let attempt: @Sendable (Route) async throws -> Connection
    let discard: @Sendable (Connection) -> Void

    func run() async -> Outcome {
        await withTaskGroup(of: Event.self) { group in
            var launched = 0
            var winner: (route: Route, connection: Connection)?
            var failures: [(route: Route, error: any Error)] = []

            func launchNext() {
                guard launched < candidates.count else { return }
                let index = launched
                let candidate = candidates[index]
                launched += 1
                guard group.addTaskUnlessCancelled(operation: { [attempt] in
                    do { return .finished(index, .success(try await attempt(candidate.route))) }
                    catch { return .finished(index, .failure(error)) }
                }), launched < candidates.count else { return }
                group.addTaskUnlessCancelled {
                    try? await Task.sleep(for: candidate.headStart)
                    return .headStartElapsed(index)
                }
            }

            launchNext()
            while let event = await group.next() {
                switch event {
                case .headStartElapsed(let index):
                    if winner == nil, index == launched - 1 { launchNext() }
                case .finished(let index, .success(let connection)):
                    if winner == nil {
                        winner = (candidates[index].route, connection)
                        group.cancelAll()
                    } else {
                        discard(connection)
                    }
                case .finished(let index, .failure(let error)):
                    guard winner == nil, !Task.isCancelled else { continue }
                    failures.append((candidates[index].route, error))
                    if failures.count == candidates.count { group.cancelAll() } else { launchNext() }
                }
            }
            return Outcome(winner: winner, failures: failures)
        }
    }
}
