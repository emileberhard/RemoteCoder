import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

struct AppPerformanceReportTests {
    private struct Fixture: Codable, Sendable, Equatable {
        let category: String
        let details: [String: String]
    }

    private let timeRange = DateInterval(start: Date(timeIntervalSince1970: 100), duration: 60)
    private let fixture = Fixture(category: "futureDiagnostic", details: ["stack": "frame1\nframe2", "count": "2"])

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func segments(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func reportEnvelopePreservesFullStructuredContent() throws {
        let record = try AppPerformanceReportRecord.make(fixture, kind: .diagnostic, timeRange: timeRange)
        let line = try record.encodedLine()
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["recordType"] as? String == "metrickit")
        #expect(object["reportID"] as? String == record.reportID)
        let report = try #require(object["report"] as? [String: Any])
        #expect(report["category"] as? String == "futureDiagnostic")
        #expect(report["details"] as? [String: String] == fixture.details)
        #expect(line.last == 0x0A)
        #expect(String(decoding: line, as: UTF8.self).split(separator: "\n").count == 1)
    }

    @Test func reportIdentityIgnoresReceiptTimeAndDictionaryOrdering() throws {
        let first = try AppPerformanceReportRecord.make(
            fixture, kind: .diagnostic, timeRange: timeRange, receivedAt: Date(timeIntervalSince1970: 1_000)
        )
        let reordered = Fixture(category: fixture.category, details: ["count": "2", "stack": "frame1\nframe2"])
        let second = try AppPerformanceReportRecord.make(
            reordered, kind: .diagnostic, timeRange: timeRange, receivedAt: Date(timeIntervalSince1970: 2_000)
        )
        let otherKind = try AppPerformanceReportRecord.make(fixture, kind: .metrics, timeRange: timeRange)
        #expect(first.reportID == second.reportID)
        #expect(first.reportID != otherKind.reportID)
    }

    @Test func reportDatesKeepTheirOriginalPrecision() throws {
        struct TimestampedReport: Codable, Sendable { let eventTime: Date }
        let report = TimestampedReport(eventTime: Date(timeIntervalSince1970: 1_000.123456))
        let record = try AppPerformanceReportRecord.make(report, kind: .diagnostic, timeRange: timeRange)
        let object = try #require(JSONSerialization.jsonObject(with: record.encodedLine()) as? [String: Any])
        let encodedReport = try #require(object["report"] as? [String: Any])
        let decoded = try JSONDecoder().decode(
            TimestampedReport.self, from: JSONSerialization.data(withJSONObject: encodedReport)
        )
        #expect(decoded.eventTime == report.eventTime)
        #expect((object["ts"] as? String)?.hasSuffix("Z") == true)
    }

    @Test func offlineReportSurvivesRelaunchAndRedelivery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        #expect(try await first.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange))
        #expect(try segments(in: directory).count == 1)

        let restarted = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        #expect(try await !restarted.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange))
        let segment = try #require(segments(in: directory).first)
        #expect(try Data(contentsOf: segment).contains(Data("futureDiagnostic".utf8)))
        // Even after acknowledged delivery removes the segment, the persisted
        // receipt prevents a repeated Apple report from becoming a new upload.
        try FileManager.default.removeItem(at: segment)
        let delivered = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        #expect(try await !delivered.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange))
        #expect(try segments(in: directory).isEmpty)
    }

    @Test func interruptedReceiptWriteDoesNotDuplicateQueuedReport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        try await first.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("performance-report-receipts.json"))
        let restarted = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        #expect(try await !restarted.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange))
        #expect(try segments(in: directory).count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("performance-report-receipts.json").path))
    }

    @Test func sharedByteBudgetEvictsOldestUndeliveredReport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try AppPerformanceReportRecord.make(fixture, kind: .diagnostic, timeRange: timeRange)
        let byteLimit = try report.encodedLine().count + 100
        let exporter = DiagnosticsOutbox(directory: directory, storedByteLimit: byteLimit, deviceLabel: { "test-device" })
        try await exporter.enqueuePerformanceReport(
            fixture, kind: .diagnostic, timeRange: timeRange, receivedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = Fixture(category: "newerDiagnostic", details: fixture.details)
        try await exporter.enqueuePerformanceReport(
            newer, kind: .diagnostic, timeRange: timeRange, receivedAt: Date(timeIntervalSince1970: 2_000)
        )
        let remaining = try segments(in: directory)
        #expect(remaining.count == 1)
        let content = try Data(contentsOf: #require(remaining.first))
        #expect(content.contains(Data("newerDiagnostic".utf8)))
        #expect(content.count <= byteLimit)
    }

    @Test func failedPersistenceCannotCreateReceipt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = DiagnosticsOutbox(directory: directory, storedByteLimit: 1, deviceLabel: { "test-device" })
        await #expect(throws: DiagnosticsOutbox.PerformanceReportQueueError.self) {
            try await exporter.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        }
        #expect(try segments(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("performance-report-receipts.json").path))
    }

    @Test func pendingReportIsIncludedInSettingsExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        try await exporter.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        let archive = try #require(await exporter.exportArchive())
        defer { try? FileManager.default.removeItem(at: archive) }
        let lines = try String(contentsOf: archive, encoding: .utf8).split(separator: "\n")
        let reports = try lines.compactMap { line -> [String: Any]? in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["recordType"] as? String == "metrickit" ? object : nil
        }
        #expect(reports.count == 1)
        #expect((reports.first?["report"] as? [String: Any])?["category"] as? String == fixture.category)
    }

    @Test func unreadableSegmentDoesNotBlockHealthyLogExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("000-bad.jsonl"), withIntermediateDirectories: true)
        let exporter = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        try await exporter.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        let archive = try #require(await exporter.exportArchive())
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(try String(contentsOf: archive, encoding: .utf8).contains("futureDiagnostic"))
        #expect(try String(contentsOf: archive, encoding: .utf8).contains("exportWarning"))
    }

    @Test func oversizedUploadIsQuarantinedOnceAndRemainsExportableAfterRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = GatewayHostConfiguration(id: UUID(), name: "Fixture", hostname: "diagnostics.test", port: 8787, authToken: "fixture-token")
        let exporter = DiagnosticsOutbox(directory: directory, uploadByteLimit: 1, deviceLabel: { "test-device" })
        await exporter.setDestination(.unreachable(host))
        try await exporter.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        #expect(await exporter.uploadPendingSegments().segments == 0)
        #expect(try segments(in: directory).isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "export-only" }
        #expect(quarantined.count == 1)
        let restored = DiagnosticsOutbox(directory: directory, uploadByteLimit: 1, deviceLabel: { "test-device" })
        await restored.setDestination(.unreachable(host))
        #expect(await restored.uploadPendingSegments().segments == 0)
        let archive = try #require(await restored.exportArchive())
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(try String(contentsOf: archive, encoding: .utf8).contains("futureDiagnostic"))
    }

    @Test func failedUploadRetainsReportAndRetryUsesIdenticalSegment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportUploadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let exporter = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        let hostname = "\(UUID().uuidString.lowercased()).diagnostics.test"
        await exporter.setDestination(DiagnosticsDestination(host: GatewayHostConfiguration(
            id: UUID(), name: "Fixture", hostname: hostname, port: 8787, authToken: "fixture-token"
        )) { try await session.data(for: $0) })
        try await exporter.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        let raw = try Data(contentsOf: #require(segments(in: directory).first))
        #expect(await exporter.uploadPendingSegments().segments == 0)
        #expect(try segments(in: directory).count == 1)
        #expect(await exporter.uploadPendingSegments().segments == 1)
        #expect(try segments(in: directory).isEmpty)
        let requests = ReportUploadProtocol.requests.withLock { $0[hostname] ?? [] }
        try #require(requests.count == 2)
        #expect(requests[0].body == GzipEncoding.gzipped(raw))
        #expect(requests[0].body == requests[1].body)
        #expect(requests[0].segment == requests[1].segment)
        #expect(requests[0].authorization == "Bearer fixture-token")
    }

    @Test(arguments: [(422, true), (400, false), (413, false), (503, false)])
    func hostRejectionQuarantinesOnlySegmentSpecificRefusals(status: Int, quarantines: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        let refused = Mutex<String?>(nil)
        await exporter.setDestination(DiagnosticsDestination(host: GatewayHostConfiguration(
            id: UUID(), name: "Fixture", hostname: "rejecting.diagnostics.test", port: 8787, authToken: "fixture-token"
        )) { request in
            let segment = request.value(forHTTPHeaderField: "X-RemoteCoder-Segment")
            let code = refused.withLock { first in
                if first == nil { first = segment }
                return first == segment ? status : 200
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badServerResponse) }
            return (Data(), response)
        })
        try await exporter.enqueuePerformanceReport(fixture, kind: .diagnostic, timeRange: timeRange)
        try await exporter.enqueuePerformanceReport(
            Fixture(category: "otherDiagnostic", details: [:]), kind: .diagnostic, timeRange: timeRange
        )
        #expect(await exporter.uploadPendingSegments().segments == (quarantines ? 1 : 0))
        let rejected = try #require(refused.withLock { $0 })
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains("\(rejected).jsonl.export-only") == quarantines)
        #expect(try segments(in: directory).count == (quarantines ? 0 : 2))
        let losses = exporter.telemetry.take().filter {
            if case .loss(let loss) = $0.record { loss.what == .metricKitSegment } else { false }
        }
        #expect(losses.count == (quarantines ? 1 : 0))
    }
}

private final class ReportUploadProtocol: URLProtocol, @unchecked Sendable {
    struct Received: Sendable {
        let body: Data
        let segment: String?
        let authorization: String?
    }
    static let requests = Mutex<[String: [Received]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let status = Self.requests.withLock { requests in
            requests[host, default: []].append(Received(
                body: body, segment: request.value(forHTTPHeaderField: "X-RemoteCoder-Segment"),
                authorization: request.value(forHTTPHeaderField: "Authorization")
            ))
            return requests[host]?.count == 1 ? 503 : 200
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
