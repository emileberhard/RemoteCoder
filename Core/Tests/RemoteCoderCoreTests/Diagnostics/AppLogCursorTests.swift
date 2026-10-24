import Foundation
import Testing
@testable import RemoteCoderCore

struct AppLogCursorTests {
    @Test func logUploadUsesTheHostTLSOrigin() throws {
        let host = GatewayHostConfiguration(id: UUID(), name: "TLS", hostname: "example.test", port: 8443,
                                            authToken: "test", transport: .tls)
        let url = try #require(DiagnosticsOutbox.appLogsURL(for: host))
        #expect(url.absoluteString == "https://example.test:8443/app-logs")
    }

    private func advance(cursor: AppLogCursor, records: [AppLogRecord]) -> (emit: [AppLogRecord], cursor: AppLogCursor) {
        var resume = AppLogResume(cursor: cursor)
        let emit = records.flatMap { resume.accept($0) } + resume.finish()
        guard let last = emit.last else { return ([], cursor) }
        return (emit, AppLogCursor(date: last.ts, lastSignature: last.signature))
    }

    private func encode(_ records: [AppLogRecord]) throws -> Data {
        let encoder = DiagnosticsOutbox.recordEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        return data
    }

    private func record(_ offset: TimeInterval, _ message: String) -> AppLogRecord {
        AppLogRecord(
            ts: Date(timeIntervalSince1970: 1_787_000_000 + offset),
            level: "notice",
            subsystem: "RemoteCoder",
            category: "Test",
            message: message,
            process: "RemoteCoder",
            thread: 1
        )
    }

    @Test func resumingSkipsExactlyWhatWasAlreadyEmitted() {
        let first = [record(0, "a"), record(1, "b")]
        let (initial, cursor) = advance(cursor: .beginning, records: first)
        #expect(initial == first)
        #expect(cursor.date == first[1].ts)
        #expect(cursor.lastSignature == first[1].signature)

        // The store still returns the boundary record on the next read.
        let second = [record(1, "b"), record(2, "c"), record(3, "d")]
        let (emit, advanced) = advance(cursor: cursor, records: second)

        #expect(emit.map(\.message) == ["c", "d"], "the boundary record must not repeat")
        #expect(advanced.lastSignature == second[2].signature)
    }

    @Test func recordsSharingTheCursorTimestampAreNotLost() {
        // Three entries logged within the same instant; only the first two were
        // emitted last time. A date-only cursor would drop the third.
        let simultaneous = [record(5, "one"), record(5, "two"), record(5, "three")]
        let (_, cursor) = advance(
            cursor: .beginning,
            records: Array(simultaneous.prefix(2))
        )

        let (emit, _) = advance(cursor: cursor, records: simultaneous)

        #expect(emit.map(\.message) == ["three"])
    }

    @Test func emptyAndOlderBatchesLeaveTheCursorWhereItWas() {
        let (_, cursor) = advance(cursor: .beginning, records: [record(10, "recent")])
        let batches: [[AppLogRecord]] = [[], [record(1, "stale"), record(2, "also stale")]]
        for records in batches {
            let (emit, advanced) = advance(cursor: cursor, records: records)
            #expect(emit.isEmpty)
            #expect(advanced == cursor)
        }
    }

    @Test func encodingProducesOneJSONObjectPerLine() throws {
        let data = try encode([record(0, "a"), record(1, "b")])

        let lines = try #require(String(data: data, encoding: .utf8))
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["subsystem"] as? String == "RemoteCoder")
        }
    }

    @Test func encodedTimestampsRoundTripToTheSameInstant() throws {
        // Asserting only that the string holds a "." passed happily on a
        // time-of-day string with no date at all, which shipped to a device
        // before a real segment was read back. Parse it instead.
        let original = record(1.234, "a")
        let data = try encode([original])
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ts = try #require(object["ts"] as? String)

        let parsed = try Date(ts, strategy: DiagnosticsOutbox.timestampStyle)
        #expect(
            abs(parsed.timeIntervalSince1970 - original.ts.timeIntervalSince1970) < 0.001,
            "app and host records interleave by ts, so it must carry the full date and millis: \(ts)"
        )
        #expect(ts.hasSuffix("Z"), "timestamps are UTC like the gateway journal's: \(ts)")
    }
}
