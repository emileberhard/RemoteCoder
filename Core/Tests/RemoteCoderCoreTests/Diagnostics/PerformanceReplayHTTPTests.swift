import Foundation
import Testing
@testable import RemoteCoderCore

@Suite(.serialized) struct PerformanceReplayHTTPTests {
    @Test func httpFixtureServesCapturedResponsesAndBlocksExternalRequests() async throws {
        try PerformanceReplayHTTP.install(["GET /accounts": .object(["status": .number(200),
            "body": .object(["captured": .bool(true)])])])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerformanceReplayHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let local = try #require(URL(string: "http://127.0.0.1:1/accounts"))
        let (data, response) = try await session.data(from: local)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object(["captured": .bool(true)]))
        let external = try #require(URL(string: "https://example.invalid/accounts"))
        await #expect(throws: URLError.self) { try await session.data(from: external) }
        let diagnostics = PerformanceReplayHTTP.diagnostics()
        #expect(diagnostics.requests == ["GET /accounts": 1])
        #expect(diagnostics.blockedExternal == 1)
        #expect(diagnostics.missing.isEmpty)
        let health = try #require(URL(string: "http://127.0.0.1:1/health"))
        let (_, missingHealth) = try await session.data(from: health)
        #expect((missingHealth as? HTTPURLResponse)?.statusCode == 404)
        #expect(PerformanceReplayHTTP.diagnostics().unrecordedHealthRequests == 1)
        #expect(PerformanceReplayHTTP.diagnostics().missing.isEmpty)
        let unknown = try #require(URL(string: "http://127.0.0.1:1/uncaptured"))
        await #expect(throws: URLError.self) { try await session.data(from: unknown) }
        #expect(PerformanceReplayHTTP.diagnostics().missing == ["GET /uncaptured"])
        try PerformanceReplayHTTP.install(["GET /health": .object(["status": .number(200),
            "body": .object(["captured": .bool(true)])])])
        let (healthBody, capturedHealth) = try await session.data(from: health)
        #expect((capturedHealth as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: healthBody) == .object(["captured": .bool(true)]))
        #expect(PerformanceReplayHTTP.diagnostics().unrecordedHealthRequests == 0)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try PerformanceReplayHTTP.install(["POST /app-logs": .object(["status": .number(200), "body": .object([:])])], telemetryDirectory: directory)
        let body = try #require(GzipEncoding.gzipped(Data("synthetic telemetry".utf8)))
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:1/app-logs")))
        request.httpMethod = "POST"
        request.setValue("synthetic-telemetry", forHTTPHeaderField: "X-RemoteCoder-Segment")
        request.httpBodyStream = InputStream(data: body)
        _ = try await session.data(for: request)
        let name = try #require(PerformanceReplayHTTP.telemetryCapture.files.first)
        #expect(PerformanceReplayHTTP.telemetryCapture.failures.isEmpty)
        #expect(try Data(contentsOf: directory.appending(path: name)) == body)
    }

    @Test func missingPendingTelemetryIsEmptyButAnUnreadableSpoolFails() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try PerformanceReplayHTTP.install([:], telemetryDirectory: root.appending(path: "captured"))
        await PerformanceReplayHTTP.retainPendingTelemetry(at: root.appending(path: "missing"))
        #expect(PerformanceReplayHTTP.telemetryCapture.files.isEmpty)
        #expect(PerformanceReplayHTTP.telemetryCapture.failures.isEmpty)
        let notDirectory = root.appending(path: "not-a-directory")
        try Data().write(to: notDirectory)
        await PerformanceReplayHTTP.retainPendingTelemetry(at: notDirectory)
        #expect(PerformanceReplayHTTP.telemetryCapture.failures == ["Could not read pending telemetry uploads"])
    }
}
