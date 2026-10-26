#if RC_PERF_HARNESS
import Foundation

@MainActor
enum PerformanceReplayFixtureControl {
    enum Mode: String { case fixture, empty }

    static func run(_ url: URL, mode: Mode) async throws -> [String: Any] {
        try await Task.sleep(for: .seconds(2))
        var samples = [sample("baseline")]
        var hash: String?
        if mode == .fixture {
            let result = try await loadedSamples(url)
            samples += result.0
            hash = result.1
        } else {
            for index in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                samples.append(sample("empty-\(index)"))
            }
        }
        try await Task.sleep(for: .seconds(2))
        samples.append(sample("released"))
        return ["mode": mode.rawValue, "samples": samples,
            "fixtureSHA256": hash.map { $0 as Any } ?? NSNull(),
            "harnessSHA256": Bundle.main.object(forInfoDictionaryKey: "RemoteCoderPerfHarnessSHA256") ?? NSNull(),
            "scope": "fresh-process fixture-only control; state reducer and response bytes; excludes app sessions and Network buffers"]
    }

    private static func loadedSamples(_ url: URL) async throws -> ([[String: Any]], String) {
        let (scenario, hash, root) = try await PerformanceReplayRun.preparedFixture(url)
        var state = try PerformanceReplayState(scenario, fixtureRoot: root)
        try await Task.sleep(for: .seconds(2))
        var samples = [sample("loaded")]
        var eventIndex = 0
        for (index, action) in scenario.actions.enumerated() {
            while eventIndex < scenario.events.count, scenario.events[eventIndex].at <= action.at {
                state.apply(scenario.events[eventIndex].frame)
                eventIndex += 1
            }
            if action.kind == .open {
                for method in ["thread/subscribe", "thread/items/list"] {
                    let request: JSONValue = .object(["id": .number(Double(index)), "method": .string(method),
                        "params": .object(["threadId": .string(action.threadID), "limit": .number(50), "sortDirection": .string("desc")])])
                    guard let response = try state.response(to: request) else {
                        throw PerformanceReplayScenario.Failure.invalidScenario("fixture control response missing")
                    }
                    let data = try response.encoded()
                    samples.append(withExtendedLifetime(data) { sample("response-\(index)-\(method)", responseBytes: data.count) })
                }
            }
            samples.append(sample("action-\(index)"))
        }
        while eventIndex < scenario.events.count {
            state.apply(scenario.events[eventIndex].frame)
            eventIndex += 1
        }
        samples.append(withExtendedLifetime((scenario, state)) { sample("complete") })
        return (samples, hash)
    }

    private static func sample(_ stage: String, responseBytes: Int = 0) -> [String: Any] {
        let resources = ProcessResources.current()
        return ["stage": stage, "at": Date.now.timeIntervalSince1970,
            "footprintMiB": resources.map { Double($0.footprintBytes) / 1_048_576 as Any } ?? NSNull(),
            "processCPUms": resources.map { Double($0.cpuNanoseconds) / 1_000_000 as Any } ?? NSNull(),
            "responseBytes": responseBytes]
    }
}
#endif
