import Foundation
import Testing
@testable import RemoteCoderCore

struct DiagnosticsLifecycleTests {
    @Test @MainActor func constructingTheExporterDoesNotOpenItsDiskStoreOnTheMainActor() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = DiagnosticsOutbox(directory: directory, deviceLabel: { "Fixture" })
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await exporter.enqueue(line: Data("diagnostic\n".utf8), kind: "fixture")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let segment = try #require(files.first { $0.pathExtension == "jsonl" })
        #expect(try String(contentsOf: segment, encoding: .utf8) == "diagnostic\n")
    }

    @Test @MainActor func hostChangesDuringDestinationAdmissionPreserveTheRequiredBackgroundDrain() async {
        let exporter = HeldDestinationExporter()
        let lifecycle = DiagnosticsLifecycle(exporter: exporter)
        let host = GatewayHostConfiguration(id: UUID(), name: "Latest", hostname: "latest.test", port: 1, authToken: "test")
        lifecycle.update(destination: nil, phase: .background)
        await exporter.waitForDestination()
        lifecycle.setDestination(.unreachable(host))
        await exporter.releaseDestination()
        await lifecycle.flush()
        #expect(await exporter.host == host)
        #expect(await exporter.operations == ["background", "stop"])
    }

    @Test @MainActor func reactivationAndHostChangesSupersedeAnAwaitingBackgroundStop() async {
        let exporter = DiagnosticsExporterFixture()
        let lifecycle = DiagnosticsLifecycle(exporter: exporter)
        let old = GatewayHostConfiguration(id: UUID(), name: "Old", hostname: "old.test", port: 1, authToken: "test")
        let latest = GatewayHostConfiguration(id: UUID(), name: "Latest", hostname: "latest.test", port: 1, authToken: "test")
        lifecycle.update(destination: .unreachable(old), phase: .background)
        await exporter.waitForDrain()
        lifecycle.update(destination: .unreachable(old), phase: .foreground("foreground"))
        lifecycle.setDestination(.unreachable(latest))
        await exporter.releaseDrain()
        await lifecycle.flush()
        #expect(await exporter.host == latest)
        #expect(await exporter.isPumping)
        #expect(await exporter.stopCount == 0)
        #expect(await exporter.drainReasons == ["background", "foreground"])
        lifecycle.setDestination(.unreachable(old))
        await lifecycle.flush()
        #expect(await exporter.host == old)
        #expect(await exporter.drainReasons == ["background", "foreground"])
        lifecycle.update(destination: .unreachable(latest), phase: .stopped)
        await lifecycle.flush()
        #expect(await exporter.stopCount == 1)
        #expect(await exporter.isPumping == false)
    }
}

private actor DiagnosticsExporterFixture: DiagnosticsExporting {
    private(set) var host: GatewayHostConfiguration?
    private(set) var isPumping = false
    private(set) var stopCount = 0
    private(set) var drainReasons: [String] = []
    private var drainWaiter: CheckedContinuation<Void, Never>?
    private var heldDrain: CheckedContinuation<Void, Never>?

    func setDestination(_ destination: DiagnosticsDestination?) { host = destination?.host }
    func startPumping() { isPumping = true }
    func stopPumping() { isPumping = false; stopCount += 1 }
    func drain(reason: String) async {
        drainReasons.append(reason)
        guard drainReasons.count == 1 else { return }
        await withCheckedContinuation {
            heldDrain = $0
            drainWaiter?.resume()
            drainWaiter = nil
        }
    }
    func waitForDrain() async {
        guard heldDrain == nil else { return }
        await withCheckedContinuation { drainWaiter = $0 }
    }
    func releaseDrain() {
        heldDrain?.resume()
        heldDrain = nil
    }
}

private actor HeldDestinationExporter: DiagnosticsExporting {
    private(set) var host: GatewayHostConfiguration?
    private(set) var operations: [String] = []
    private var admissionWaiter: CheckedContinuation<Void, Never>?
    private var heldAdmission: CheckedContinuation<Void, Never>?
    private var hasAdmitted = false

    func setDestination(_ destination: DiagnosticsDestination?) async {
        if !hasAdmitted {
            hasAdmitted = true
            await withCheckedContinuation {
                heldAdmission = $0
                admissionWaiter?.resume()
                admissionWaiter = nil
            }
        }
        host = destination?.host
    }
    func startPumping() {}
    func stopPumping() { operations.append("stop") }
    func drain(reason: String) { operations.append(reason) }
    func waitForDestination() async {
        guard heldAdmission == nil else { return }
        await withCheckedContinuation { admissionWaiter = $0 }
    }
    func releaseDestination() {
        heldAdmission?.resume()
        heldAdmission = nil
    }
}

extension DiagnosticsDestination {
    static func unreachable(_ host: GatewayHostConfiguration) -> DiagnosticsDestination {
        DiagnosticsDestination(host: host) { _ in throw URLError(.cannotConnectToHost) }
    }
}
