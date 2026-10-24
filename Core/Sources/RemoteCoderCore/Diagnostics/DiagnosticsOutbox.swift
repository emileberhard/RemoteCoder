import Foundation
import OSLog

/// One drained OSLog entry, as it is written to a segment file.
struct AppLogRecord: Codable, Sendable, Equatable {
    let ts: Date
    let level: String
    let subsystem: String
    let category: String
    let message: String
    let process: String?
    let thread: UInt64?

    /// Identifies this exact entry within its timestamp, so a drain that
    /// resumes at the same date can tell which entries it already emitted.
    var signature: String {
        var hasher = Hasher()
        hasher.combine(ts)
        hasher.combine(subsystem)
        hasher.combine(category)
        hasher.combine(message)
        return String(hasher.finalize(), radix: 16)
    }
}

/// Where the next drain resumes.
///
/// A date alone is not enough: several entries share a timestamp, so the
/// signature of the last one emitted marks the exact resume point.
struct AppLogCursor: Codable, Sendable, Equatable {
    var date: Date
    var lastSignature: String?

    static let beginning = AppLogCursor(date: .distantPast, lastSignature: nil)
}

struct AppLogResume {
    private let cursor: AppLogCursor
    private var held: [AppLogRecord] = []
    private var resolved: Bool

    init(cursor: AppLogCursor) {
        self.cursor = cursor
        resolved = cursor.lastSignature == nil
    }

    mutating func accept(_ record: AppLogRecord) -> [AppLogRecord] {
        guard record.ts >= cursor.date else { return [] }
        if resolved { return [record] }
        if record.ts == cursor.date {
            if record.signature == cursor.lastSignature {
                held.removeAll()
                resolved = true
            } else {
                held.append(record)
            }
            return []
        }
        resolved = true
        defer { held.removeAll() }
        return held + [record]
    }

    mutating func finish() -> [AppLogRecord] {
        defer { held.removeAll() }
        return resolved ? [] : held
    }
}

struct DiagnosticsUpload: Sendable, Equatable {
    var segments = 0
    var bytes = 0
    var compressMilliseconds = 0.0
    var uploadMilliseconds = 0.0
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

struct DiagnosticsDestination: Sendable {
    let host: GatewayHostConfiguration
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
}

/// Drains this process's complete OSLog stream to disk and ships it to the
/// gateway host.
///
/// The phone's log store rotates within hours, so anything a bug report would
/// need is usually gone before anyone asks. Everything the process logged —
/// every subsystem, category and level, including debug — is drained here,
/// deliberately not a curated subset: the host copy has to be able to answer a
/// question nobody thought to instrument for.
actor DiagnosticsOutbox: DiagnosticsExporting, TelemetryRecording {
    /// The exporter's own category, excluded from every drain so uploading a
    /// segment cannot generate the next one.
    static let loggerCategory = "AppLogExport"

    /// Total on-device bytes of undelivered segments before the oldest are
    /// evicted. Uploaded segments are deleted immediately, so this only fills
    /// up while the host is unreachable.
    private static let maximumStoredBytes = 50 * 1024 * 1024
    private static let maximumRememberedReports = 1_024
    private static let maximumUploadBytes = 16 * 1024 * 1024
    private static let drainInterval: Duration = .seconds(300)
    private static let maximumSegmentRecords = 10_000
    private static let maximumBufferedTelemetry = 256

    private let logger = Logger(subsystem: "RemoteCoder", category: DiagnosticsOutbox.loggerCategory)
    private let directory: URL
    private let cursorURL: URL
    private let reportReceiptsURL: URL
    private let storedByteLimit: Int
    private let uploadByteLimit: Int
    private var skippedSegments: Set<String> = []
    private var hasLoaded = false
    private var cursor: AppLogCursor
    private var reportReceipts: [String]
    private var destination: DiagnosticsDestination?
    private var pump: Task<Void, Never>?
    private let deviceLabel: @Sendable () async -> String
    private var cachedDeviceName: String?
    private var isUploading = false
    private var drainTask: Task<Void, Never>?
    private var run: TelemetryRun
    private var telemetry: [TelemetryLine] = []
    private var nextTelemetrySeq: UInt64 = 1
    private var droppedTelemetry = 0
    private let clock = ContinuousClock()

    init(
        directory: URL? = nil,
        storedByteLimit: Int = DiagnosticsOutbox.maximumStoredBytes,
        uploadByteLimit: Int = DiagnosticsOutbox.maximumUploadBytes,
        deviceLabel: @escaping @Sendable () async -> String
    ) {
        precondition(storedByteLimit > 0)
        let base = directory ?? Self.defaultDirectory()
        self.directory = base
        self.storedByteLimit = storedByteLimit
        self.uploadByteLimit = uploadByteLimit
        self.deviceLabel = deviceLabel
        cursorURL = base.appendingPathComponent("cursor.json", isDirectory: false)
        reportReceiptsURL = base.appendingPathComponent("performance-report-receipts.json", isDirectory: false)
        cursor = .beginning
        reportReceipts = []
        run = TelemetryRun.make(installationID: nil)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cursor = (try? JSONDecoder().decode(AppLogCursor.self, from: Data(contentsOf: cursorURL))) ?? .beginning
        reportReceipts = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: reportReceiptsURL))) ?? []
        hasLoaded = true
    }

    private static func defaultDirectory() -> URL {
        return AppStorageScope.current.applicationSupport
            .appendingPathComponent("RemoteCoder", isDirectory: true)
            .appendingPathComponent("app-logs", isDirectory: true)
    }

    /// The gateway the segments are shipped to. Segments accumulate on disk
    /// when this is nil or unreachable and go out on the next successful pass.
    func setDestination(_ destination: DiagnosticsDestination?) {
        self.destination = destination
    }

    // Breadcrumbs are persisted directly instead of waiting for the next
    // OSLog drain, so a later process launch can still upload the failure.
    func enqueue(line data: Data, kind: String) throws {
        loadIfNeeded()
        let started = ContinuousClock.now
        let name = "\(Self.segmentStamp())-\(kind).jsonl"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        PersistenceMetrics.shared.wrote(.diagnostics, bytes: data.count, elapsed: started.duration(to: .now))
        evictOldestBeyondCap()
    }

    /// A receipt becomes durable only after the complete report is on disk.
    /// A replay after an interrupted receipt write finds the existing segment.
    @discardableResult
    func enqueuePerformanceReport<Report: Encodable & Sendable>(
        _ report: Report, kind: AppPerformanceReportKind, timeRange: DateInterval,
        receivedAt: Date = .now
    ) throws -> Bool {
        loadIfNeeded()
        let started = ContinuousClock.now
        let record = try AppPerformanceReportRecord.make(
            report, kind: kind, timeRange: timeRange, receivedAt: receivedAt
        )
        guard !reportReceipts.contains(record.reportID) else { return false }
        let suffix = "-mk-\(record.reportID.prefix(40)).jsonl"
        let alreadyQueued = pendingSegments(includingExportOnly: true).contains {
            let name = $0.pathExtension == "export-only" ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent
            return name.hasSuffix(suffix)
        }
        if !alreadyQueued {
            let data = try record.encodedLine()
            guard data.count <= storedByteLimit else {
                throw PerformanceReportQueueError.exceedsStorageLimit(bytes: data.count, limit: storedByteLimit)
            }
            let milliseconds = UInt64(receivedAt.timeIntervalSince1970 * 1_000)
            let name = String(format: "%015llu", milliseconds) + suffix
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            PersistenceMetrics.shared.wrote(.diagnostics, bytes: data.count, elapsed: started.duration(to: .now))
        }
        let updatedReceipts = Array((reportReceipts + [record.reportID]).suffix(Self.maximumRememberedReports))
        let receiptStarted = ContinuousClock.now
        let receiptData = try JSONEncoder().encode(updatedReceipts)
        try receiptData.write(to: reportReceiptsURL, options: .atomic)
        PersistenceMetrics.shared.wrote(.diagnostics, bytes: receiptData.count, elapsed: receiptStarted.duration(to: .now))
        reportReceipts = updatedReceipts
        evictOldestBeyondCap()
        return !alreadyQueued
    }

    enum PerformanceReportQueueError: LocalizedError {
        case exceedsStorageLimit(bytes: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case let .exceedsStorageLimit(bytes, limit):
                "MetricKit report has \(bytes) bytes and exceeds the \(limit)-byte diagnostic storage limit."
            }
        }
    }

    func record(_ record: TelemetryRecord) {
        let line = TelemetryLine(runID: run.runID, seq: nextTelemetrySeq, at: .now,
                                 monoNs: MachTime.continuousNanoseconds(), record: record)
        nextTelemetrySeq += 1
        if telemetry.count >= Self.maximumBufferedTelemetry {
            telemetry.removeFirst()
            droppedTelemetry += 1
        }
        telemetry.append(line)
    }

    private func flushTelemetry() -> Int {
        guard !telemetry.isEmpty || droppedTelemetry > 0 else { return 0 }
        var lines = telemetry
        if droppedTelemetry > 0 {
            lines.append(TelemetryLine(runID: run.runID, seq: nextTelemetrySeq, at: .now,
                monoNs: MachTime.continuousNanoseconds(), record: .loss(TelemetryLoss(
                    what: .telemetryRecords, count: droppedTelemetry, bytes: nil, reason: "memory buffer full"))))
        }
        run.installationID = AppStorageScope.current.defaults.string(forKey: HostStore.installationIDKey)
        let started = clock.now
        let encoder = Self.recordEncoder()
        var body = Data()
        do {
            body.append(try encoder.encode(TelemetryRunHeader(run: run, flushedThroughSeq: lines.last?.seq ?? 0)))
            body.append(0x0A)
            for line in lines {
                body.append(try encoder.encode(line))
                body.append(0x0A)
            }
            try body.write(to: directory.appendingPathComponent("\(Self.segmentStamp())-telemetry.jsonl"), options: .atomic)
        } catch {
            PersistenceMetrics.shared.failed(.diagnostics)
            logger.error("telemetry batch write failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        PersistenceMetrics.shared.wrote(.diagnostics, bytes: body.count, elapsed: started.duration(to: clock.now))
        if droppedTelemetry > 0 { nextTelemetrySeq += 1 }
        telemetry.removeAll(keepingCapacity: true)
        droppedTelemetry = 0
        return lines.count
    }

    /// Starts the periodic drain. Idempotent: calling it again while running
    /// leaves the existing pump alone.
    func startPumping() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.drainInterval, tolerance: .seconds(30)) }
                catch { return }
                await self?.drain(reason: "interval")
            }
        }
    }

    func stopPumping() {
        pump?.cancel()
        pump = nil
    }

    /// Drains new entries into a segment and ships whatever is pending.
    /// Never throws and never blocks a caller's work: a failed drain or a
    /// failed upload is retried on the next pass.
    func drain(reason: String) async {
        if let drainTask { await drainTask.value; return }
        let task = Task { await performDrain(reason: reason) }
        drainTask = task
        await task.value
        drainTask = nil
    }

    private func performDrain(reason: String) async {
        let started = clock.now
        let before = ProcessResources.current()
        var cost = ExportCost(reason: reason)
        PersistenceMetrics.shared.reportIfDue()
        cost.flushedRecords = flushTelemetry()
        drainToSegments(&cost)
        let afterScan = ProcessResources.current()
        let upload = await uploadPendingSegments()
        let after = ProcessResources.current()
        cost.uploadedSegments = upload.segments
        cost.uploadedBytes = upload.bytes
        cost.compressMilliseconds = upload.compressMilliseconds
        cost.uploadMilliseconds = upload.uploadMilliseconds
        cost.totalMilliseconds = started.duration(to: clock.now).milliseconds
        cost.footprintBefore = before?.footprintBytes
        cost.footprintAfter = after?.footprintBytes
        cost.footprintPeak = [before, afterScan, after].compactMap { $0?.footprintBytes }.max()
        if let before, let after, after.cpuNanoseconds >= before.cpuNanoseconds {
            cost.processCPUNanoseconds = after.cpuNanoseconds - before.cpuNanoseconds
        }
        record(.export(cost))
        if cost.kept > 0 || upload.segments > 0 {
            logger.debug("log drain \(reason, privacy: .public): \(cost.kept) records, \(upload.segments) segments uploaded")
        }
    }

    /// Writes every log record the app has produced into one file for the
    /// Settings share sheet, for when the phone has no gateway connectivity.
    func exportArchive() -> URL? {
        _ = flushTelemetry()
        var cost = ExportCost(reason: "archive")
        drainToSegments(&cost)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCoder-logs-\(Self.segmentStamp()).jsonl")
        guard let out = OutputStream(url: destination, append: false) else { return nil }
        out.open()
        defer { out.close() }
        for segment in pendingSegments(includingExportOnly: true) {
            let data: Data
            do { data = try Data(contentsOf: segment) }
            catch {
                logger.error("Skipping unreadable segment in log export: \(segment.lastPathComponent, privacy: .public)")
                let warning = ["recordType": "exportWarning", "segment": segment.lastPathComponent,
                    "message": "Unreadable segment omitted from this export"]
                guard var encoded = try? JSONEncoder().encode(warning) else { continue }
                encoded.append(0x0A)
                data = encoded
            }
            let complete = data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return data.isEmpty }
                var written = 0
                while written < data.count {
                    let count = out.write(base.advanced(by: written), maxLength: data.count - written)
                    guard count > 0 else { return false }
                    written += count
                }
                return true
            }
            guard complete else {
                logger.error("Log export destination failed while writing")
                return nil
            }
        }
        return destination
    }

    // MARK: - Draining

    private func drainToSegments(_ cost: inout ExportCost) {
        loadIfNeeded()
        let started = clock.now
        let encoder = Self.recordEncoder()
        var resume = AppLogResume(cursor: cursor)
        var body = Data()
        var pending = 0
        var last: AppLogRecord?
        var encoding: Duration = .zero
        var writing: Duration = .zero
        var failed = false

        func emit(_ record: AppLogRecord) {
            let encodeStarted = clock.now
            guard let line = try? encoder.encode(record) else { return }
            body.append(line)
            body.append(0x0A)
            encoding += encodeStarted.duration(to: clock.now)
            pending += 1
            last = record
            if pending >= Self.maximumSegmentRecords { writeSegment() }
        }

        func writeSegment() {
            guard pending > 0, !failed, let last else { return }
            let writeStarted = clock.now
            let url = directory.appendingPathComponent("\(Self.segmentStamp()).jsonl", isDirectory: false)
            do {
                try body.write(to: url, options: .atomic)
                PersistenceMetrics.shared.wrote(.diagnostics, bytes: body.count, elapsed: writeStarted.duration(to: clock.now))
            } catch {
                logger.error("segment write failed: \(error.localizedDescription, privacy: .public)")
                failed = true
                return
            }
            cost.segments += 1
            cost.bytes += body.count
            cost.kept += pending
            cursor = AppLogCursor(date: last.ts, lastSignature: last.signature)
            persistCursor()
            writing += writeStarted.duration(to: clock.now)
            body.removeAll(keepingCapacity: true)
            pending = 0
        }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = cursor.date
            for entry in try store.getEntries(at: store.position(date: since)) {
                cost.scanned += 1
                guard !failed else { break }
                guard entry.date >= since else { continue }
                let log = entry as? OSLogEntryLog
                let category = log?.category ?? ""
                // The uploader's own lines would otherwise seed the next segment.
                guard category != Self.loggerCategory else { continue }
                let record = AppLogRecord(
                    ts: entry.date,
                    level: Self.levelName(log?.level),
                    subsystem: log?.subsystem ?? "",
                    category: category,
                    message: entry.composedMessage,
                    process: log?.process,
                    thread: log?.threadIdentifier
                )
                for ready in resume.accept(record) { emit(ready) }
            }
            for ready in resume.finish() { emit(ready) }
        } catch {
            logger.error("OSLogStore drain failed: \(error.localizedDescription, privacy: .public)")
        }
        writeSegment()
        if cost.segments > 0 { evictOldestBeyondCap() }
        cost.encodeMilliseconds = encoding.milliseconds
        cost.writeMilliseconds = writing.milliseconds
        cost.scanMilliseconds = max(0, started.duration(to: clock.now).milliseconds - cost.encodeMilliseconds - cost.writeMilliseconds)
    }

    /// Full RFC 3339 UTC date-time with millis. `ISO8601FormatStyle` is a value
    /// type, unlike `ISO8601DateFormatter`, so it crosses into the encoder's
    /// sendable closure.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func recordEncoder() -> JSONEncoder {
        // Millisecond precision, matching the gateway journal's `ts`, so app
        // and host records can be interleaved by time. Plain `.iso8601`
        // truncates to whole seconds and loses the ordering that matters.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.timestampStyle))
        }
        return encoder
    }

    private static func levelName(_ level: OSLogEntryLog.Level?) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "undefined"
        default: "unknown"
        }
    }

    // MARK: - Segment files

    /// Fixed-width millisecond prefix so the file names sort chronologically.
    private static func segmentStamp() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        return String(format: "%015llu-%@", millis, UUID().uuidString.prefix(8).lowercased())
    }

    private func pendingSegments(includingExportOnly: Bool = false) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { $0.pathExtension == "jsonl" || (includingExportOnly && $0.pathExtension == "export-only") }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    private func evictOldestBeyondCap() {
        var segments = pendingSegments(includingExportOnly: true)
        var total = segments.reduce(0) { $0 + Self.fileSize($1) }
        guard total > storedByteLimit else { return }
        segments.sort { (Self.evictionClass($0).rawValue, $0.lastPathComponent) < (Self.evictionClass($1).rawValue, $1.lastPathComponent) }
        var evicted: [TelemetryLoss.What: (count: Int, bytes: Int)] = [:]
        while total > storedByteLimit, let oldest = segments.first {
            let size = Self.fileSize(oldest)
            total -= size
            try? FileManager.default.removeItem(at: oldest)
            segments.removeFirst()
            evicted[Self.evictionClass(oldest).loss, default: (0, 0)].count += 1
            evicted[Self.evictionClass(oldest).loss, default: (0, 0)].bytes += size
        }
        for (what, loss) in evicted.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            logger.notice("evicted \(loss.count, privacy: .public) undelivered \(what.rawValue, privacy: .public) segments to stay under the on-device cap")
            record(.loss(TelemetryLoss(what: what, count: loss.count, bytes: loss.bytes, reason: "on-device queue cap")))
        }
    }

    private enum EvictionClass: Int {
        case log, telemetry, metricKit

        var loss: TelemetryLoss.What {
            switch self {
            case .log: .logSegment
            case .telemetry: .telemetrySegment
            case .metricKit: .metricKitSegment
            }
        }
    }

    private static func evictionClass(_ url: URL) -> EvictionClass {
        let name = url.pathExtension == "export-only" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        if name.contains("-mk-") { return .metricKit }
        return name.hasSuffix("-telemetry.jsonl") ? .telemetry : .log
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func persistCursor() {
        let started = ContinuousClock.now
        do {
            let data = try JSONEncoder().encode(cursor)
            try data.write(to: cursorURL, options: .atomic)
            PersistenceMetrics.shared.wrote(.diagnostics, bytes: data.count, elapsed: started.duration(to: .now))
        } catch { PersistenceMetrics.shared.failed(.diagnostics) }
    }

    // MARK: - Uploading

    func uploadPendingSegments() async -> DiagnosticsUpload {
        loadIfNeeded()
        evictOldestBeyondCap()
        var result = DiagnosticsUpload()
        guard !isUploading else { return result }
        guard let destination, let url = Self.appLogsURL(for: destination.host) else { return result }
        isUploading = true
        defer { isUploading = false }
        for segment in pendingSegments() {
            guard !skippedSegments.contains(segment.lastPathComponent) else { continue }
            let compressStarted = clock.now
            guard Self.fileSize(segment) <= storedByteLimit,
                  let raw = try? Data(contentsOf: segment),
                  let body = GzipEncoding.gzipped(raw) else {
                quarantine(segment, reason: "unreadable or over storage limit")
                continue
            }
            result.compressMilliseconds += compressStarted.duration(to: clock.now).milliseconds
            guard body.count <= uploadByteLimit else {
                quarantine(segment, reason: "compressed segment exceeds upload limit")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(destination.host.authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
            request.setValue(await deviceName(), forHTTPHeaderField: "X-RemoteCoder-Device")
            request.setValue(
                segment.deletingPathExtension().lastPathComponent,
                forHTTPHeaderField: "X-RemoteCoder-Segment"
            )
            request.httpBody = body
            request.timeoutInterval = 30

            let uploadStarted = clock.now
            let response = try? await destination.send(request).1
            result.uploadMilliseconds += uploadStarted.duration(to: clock.now).milliseconds
            guard let response, let status = (response as? HTTPURLResponse)?.statusCode else {
                // Host unreachable. Keep the segment and try again next pass.
                return result
            }
            guard (200..<300).contains(status) else {
                logger.error("app log upload rejected with \(status, privacy: .public)")
                return result
            }
            try? FileManager.default.removeItem(at: segment)
            result.segments += 1
            result.bytes += body.count
        }
        return result
    }

    private func quarantine(_ segment: URL, reason: String) {
        skippedSegments.insert(segment.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: segment, to: segment.appendingPathExtension("export-only"))
            logger.error("Log segment retained for export under queue cap: \(reason, privacy: .public)")
        } catch {
            logger.error("Could not quarantine log segment; skipped until relaunch: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func appLogsURL(for host: GatewayHostConfiguration) -> URL? {
        host.gatewayHTTPBaseURL()?.appending(path: "app-logs")
    }

    /// A stable, already-safe directory name for this device, resolved once and kept.
    private func deviceName() async -> String {
        if let cachedDeviceName { return cachedDeviceName }
        let resolved = await deviceLabel()
        cachedDeviceName = resolved
        return resolved
    }
}
