import Testing
@testable import RemoteCoderCore

struct PerfBuildTests {
    @Test func reportsExcludeSetupAndRetainUnchangedAndNewCounters() throws {
        let setup = ["native.commit": 28, "host.prepareStarted": 2]
        let finished = ["native.commit": 170, "native.frameCommit": 74, "host.prepareStarted": 2]
        let report = try PerfBuild.CounterWindow(start: setup, end: finished).report(["label": "switch fixture"])
        let counters = try #require(report["counters"] as? [String: Int])

        #expect(counters == ["native.commit": 142, "native.frameCommit": 74, "host.prepareStarted": 0])
        #expect(report["label"] as? String == "switch fixture")
        let quiet = try PerfBuild.CounterWindow(start: finished, end: finished).report([:])
        #expect(quiet["counters"] as? [String: Int] == [
            "native.commit": 0, "native.frameCommit": 0, "host.prepareStarted": 0,
        ])
    }

    @Test func aReportCannotOverrideTheCounterWindowWithLifetimeValues() {
        let window = PerfBuild.CounterWindow(start: ["native.commit": 28], end: ["native.commit": 170])
        #expect(throws: PerfBuild.CounterWindow.ReportIssue.counterFieldAlreadyPresent) {
            try window.report(["counters": ["native.commit": 170]])
        }
    }

    @Test func idleTicksDoNotReadCounterMapsAndWritesResumeSampling() {
        var counters = PerfBuild.Counters()
        counters.count("settled")
        counters.count("settled")
        var sampler = PerfBuild.CounterSampler(start: counters)
        var reads = 0
        for _ in 0..<3 {
            #expect(sampler.tick(generation: counters.generation, read: {
                reads += 1
                return counters
            }) == nil)
        }
        #expect(reads == 0)
        counters.count("settled")
        counters.count("new")
        #expect(counters.generation == 4)
        #expect(sampler.tick(generation: counters.generation, read: {
            reads += 1
            return counters
        }) == ["settled": 1, "new": 1])
        #expect(reads == 1)
        #expect(sampler.tick(generation: counters.generation, read: {
            reads += 1
            return counters
        }) == nil)
        #expect(reads == 1)
    }

    @Test func samplingAcknowledgesWritesThatArriveAfterTheGenerationCheck() {
        var counters = PerfBuild.Counters()
        var sampler = PerfBuild.CounterSampler(start: counters)
        counters.count("changed")
        let observedGeneration = counters.generation
        var reads = 0
        #expect(sampler.tick(generation: observedGeneration, read: {
            reads += 1
            counters.count("changed")
            return counters
        }) == ["changed": 2])
        #expect(sampler.tick(generation: counters.generation, read: {
            reads += 1
            return counters
        }) == nil)
        #expect(reads == 1)
    }

}
