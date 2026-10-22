import Foundation
import Testing
@testable import RemoteCoderCore

struct BenchmarkPlanValidationTests {
    @Test func horizontalDisplacementRequiresItsOverflowCorpusAndNativeDelivery() throws {
        let scenario: [String: Any] = ["fixture": "horizontal-overflow", "checkInteraction": "horizontal-displacement"]
        try plan(changes: scenario).validate()
        for change: [String: Any] in [["fixture": NSNull()], ["checkInteraction": NSNull()], ["delivery": "send"],
            ["height": 499], ["stream": ["kind": "paragraph", "seconds": 1, "charsPerTick": 40, "tickMs": 30]],
            ["warmup": [["velocity": 1200, "dragSeconds": 1, "eased": true, "momentum": false, "pauseSeconds": 0]]],
            ["gestures": [["velocity": 1200, "dragSeconds": 1, "eased": true, "momentum": false, "pauseSeconds": 0]]]] {
            let decoded = try plan(changes: scenario.merging(change) { _, replacement in replacement })
            #expect(throws: (any Error).self) { try decoded.validate() }
        }
    }

    private func plan(changes: [String: Any]) throws -> BenchPlan {
        var input: [String: Any] = ["label": "fixture", "host": "6A71F6AF-4C5B-47F8-8A59-CFE189450A44",
            "thread": "fixture-thread", "width": 1100, "height": 760,
            "expectedDisplay": ["width": 1797, "height": 1162, "scale": 2, "maximumFramesPerSecond": 120], "pointerX": 0.5, "pointerY": 0.5,
            "settleSeconds": 1, "tailSeconds": 1, "warmup": [], "gestures": [],
            "capture": "none", "delivery": "app", "quit": true]
        input.merge(changes) { _, replacement in replacement }
        return try JSONDecoder().decode(BenchPlan.self, from: JSONSerialization.data(withJSONObject: input))
    }

    @Test func windowRestorationArgumentsAreRequired() throws {
        try BenchPlan.validateLaunch(["-rcPerfBench", "{}", "-ApplePersistenceIgnoreState", "YES",
                                      "-NSQuitAlwaysKeepsWindows", "NO"])
        for input in [["-rcPerfBench", "{}"], ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", "NO"],
            ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "YES"]] {
            #expect(throws: (any Error).self) { try BenchPlan.validateLaunch(input) }
        }
    }

    @Test func supportedPlansPassBeforeHostConstruction() throws {
        try plan(changes: [:]).validate()
        try plan(changes: ["switches": true]).validate()
        try plan(changes: ["checkInteraction": "cancelled-momentum"]).validate()
        try plan(changes: ["checkInteraction": "composer-typing"]).validate()
        try plan(changes: ["checkInteraction": "composer-editing"]).validate()
        try plan(changes: ["checkInteraction": "tracking", "stream": ["kind": "paragraph", "seconds": 1,
            "charsPerTick": 40, "tickMs": 30]]).validate()
        for check in ["narrow-zoom", "reading-growth"] {
            try plan(changes: ["checkInteraction": check, "stream": ["kind": "paragraph", "seconds": 8,
                "charsPerTick": 40, "tickMs": 30]]).validate()
        }
        for kind in ["wide-table", "wide-table-then-prose"] {
            try plan(changes: ["checkInteraction": "table-selection", "stream": ["kind": kind, "seconds": 8,
                "charsPerTick": 40, "tickMs": 30]]).validate()
        }
    }

    @Test func unsupportedStreamingInteractionIsRejected() throws {
        for check in ["cancelled-momentum", "composer-typing", "composer-editing"] {
            let input = try plan(changes: ["checkInteraction": check,
                "stream": ["kind": "paragraph", "seconds": 1, "charsPerTick": 40, "tickMs": 30]])
            #expect(throws: (any Error).self) { try input.validate() }
        }
        for check in ["tracking", "narrow-zoom", "reading-growth", "table-selection"] {
            let input = try plan(changes: ["checkInteraction": check])
            #expect(throws: (any Error).self) { try input.validate() }
        }
    }

    @Test func switchFixturesRejectOtherScenariosBeforeHostConstruction() throws {
        for extra: [String: Any] in [["account": "22222222-2222-2222-2222-222222222222"], ["checkInteraction": "cancelled-momentum"],
            ["stream": ["kind": "paragraph", "seconds": 1, "charsPerTick": 40, "tickMs": 30]],
            ["gestures": [["velocity": 1200, "dragSeconds": 1, "eased": true,
                "momentum": false, "pauseSeconds": 1]]]] {
            var changes: [String: Any] = ["switches": true]
            changes.merge(extra) { _, replacement in replacement }
            let input = try plan(changes: changes)
            #expect(throws: (any Error).self) { try input.validate() }
        }
    }

    @Test func invalidPathsGeometryAndGesturesAreRejected() throws {
        for changes: [String: Any] in [["label": "../original"], ["width": 0], ["pointerX": 2],
            ["thread": "  "], ["tailSeconds": -1], ["gestures": [["velocity": 1200, "dragSeconds": 1,
                "eased": true, "momentum": false, "pauseSeconds": -1]]]] {
            let input = try plan(changes: changes)
            #expect(throws: (any Error).self) { try input.validate() }
        }
    }

    @Test func coldTableRequiresAnIsolatedScrollingWindow() throws {
        let gesture: [String: Any] = ["velocity": 1200, "dragSeconds": 1,
            "eased": true, "momentum": false, "pauseSeconds": 0.2]
        try plan(changes: ["fixture": "cold-table", "gestures": [gesture]]).validate()
        for changes: [String: Any] in [["gestures": []],
            ["stream": ["kind": "paragraph", "seconds": 8, "charsPerTick": 40, "tickMs": 30]],
            ["checkInteraction": "cancelled-momentum"]] {
            var input: [String: Any] = ["fixture": "cold-table", "gestures": [gesture]]
            input.merge(changes) { _, replacement in replacement }
            let decoded = try plan(changes: input)
            #expect(throws: (any Error).self) { try decoded.validate() }
        }
    }
}
