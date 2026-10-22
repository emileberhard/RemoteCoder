import CryptoKit
import Foundation

enum AppPerformanceReportKind: String, Codable, Sendable {
    case metrics, diagnostic
}

/// A versioned JSONL envelope keeps the full Apple Codable report out of OSLog's
/// message limits. Identity excludes receipt time so redelivery deduplicates.
struct AppPerformanceReportRecord<Report: Encodable & Sendable>: Encodable, Sendable {
    let schemaVersion = 1
    let recordType = "metrickit"
    let ts: String
    let kind: AppPerformanceReportKind
    let reportID: String
    let coverage: DateInterval
    let report: Report

    static func make(
        _ report: Report, kind: AppPerformanceReportKind, timeRange: DateInterval,
        receivedAt: Date = .now
    ) throws -> Self {
        var identity = Data(kind.rawValue.utf8)
        identity.append(try encoder().encode(report))
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return Self(
            ts: receivedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            kind: kind, reportID: hash, coverage: timeRange, report: report
        )
    }

    func encodedLine() throws -> Data {
        var data = try Self.encoder().encode(self)
        data.append(0x0A)
        return data
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
