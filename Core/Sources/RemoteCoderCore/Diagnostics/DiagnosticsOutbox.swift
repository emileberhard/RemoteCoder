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
actor DiagnosticsOutbox: DiagnosticsExporting {
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
        PersistenceMetrics.shared.reportIfDue()
        let drained = drainToSegment()
        let uploaded = await uploadPendingSegments()
        if drained > 0 || uploaded > 0 {
            logger.debug("log drain \(reason, privacy: .public): \(drained) records, \(uploaded) segments uploaded")
        }
    }

    /// Writes every log record the app has produced into one file for the
    /// Settings share sheet, for when the phone has no gateway connectivity.
    func exportArchive() -> URL? {
        _ = drainToSegment()
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

    /// Reads everything logged since the cursor and appends it to a new
    /// segment. Returns how many records were written.
    private func drainToSegment() -> Int {
        loadIfNeeded()
        let records: [AppLogRecord]
        do {
            records = try readNewEntries()
        } catch {
            logger.error("OSLogStore drain failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        let (emit, advanced) = Self.advance(cursor: cursor, records: records)
        guard !emit.isEmpty else { return 0 }

        let started = ContinuousClock.now
        guard let body = Self.encode(emit) else { return 0 }
        let url = directory.appendingPathComponent("\(Self.segmentStamp()).jsonl", isDirectory: false)
        do {
            try body.write(to: url, options: .atomic)
            PersistenceMetrics.shared.wrote(.diagnostics, bytes: body.count, elapsed: started.duration(to: .now))
        } catch {
            logger.error("segment write failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        cursor = advanced
        persistCursor()
        evictOldestBeyondCap()
        return emit.count
    }

    private func readNewEntries() throws -> [AppLogRecord] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = cursor.date
        let position = store.position(date: since)
        return try store.getEntries(at: position).compactMap { entry -> AppLogRecord? in
            guard entry.date >= since else { return nil }
            let log = entry as? OSLogEntryLog
            let category = log?.category ?? ""
            // The uploader's own lines would otherwise seed the next segment.
            guard category != Self.loggerCategory else { return nil }
            return AppLogRecord(
                ts: entry.date,
                level: Self.levelName(log?.level),
                subsystem: log?.subsystem ?? "",
                category: category,
                message: entry.composedMessage,
                process: log?.process,
                thread: log?.threadIdentifier
            )
        }
    }

    /// Selects the records a drain should emit and where the next one resumes.
    ///
    /// Pure so the resume behaviour can be tested without an OSLogStore.
    static func advance(
        cursor: AppLogCursor,
        records: [AppLogRecord]
    ) -> (emit: [AppLogRecord], cursor: AppLogCursor) {
        var candidates = records.filter { $0.ts >= cursor.date }
        if let signature = cursor.lastSignature,
           let boundary = candidates.firstIndex(where: {
               $0.ts == cursor.date && $0.signature == signature
           }) {
            candidates.removeSubrange(...boundary)
        }
        guard let last = candidates.last else { return ([], cursor) }
        return (candidates, AppLogCursor(date: last.ts, lastSignature: last.signature))
    }

    /// Full RFC 3339 UTC date-time with millis. `ISO8601FormatStyle` is a value
    /// type, unlike `ISO8601DateFormatter`, so it crosses into the encoder's
    /// sendable closure.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func encode(_ records: [AppLogRecord]) -> Data? {
        // Millisecond precision, matching the gateway journal's `ts`, so app
        // and host records can be interleaved by time. Plain `.iso8601`
        // truncates to whole seconds and loses the ordering that matters.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.timestampStyle))
        }
        var body = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            body.append(line)
            body.append(0x0A)
        }
        return body.isEmpty ? nil : body
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
        while total > storedByteLimit, let oldest = segments.first {
            total -= Self.fileSize(oldest)
            try? FileManager.default.removeItem(at: oldest)
            segments.removeFirst()
            logger.notice("evicted an undelivered log segment to stay under the on-device cap")
        }
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

    func uploadPendingSegments() async -> Int {
        loadIfNeeded()
        evictOldestBeyondCap()
        guard !isUploading else { return 0 }
        guard let destination, let url = Self.appLogsURL(for: destination.host) else { return 0 }
        isUploading = true
        defer { isUploading = false }
        var uploaded = 0
        for segment in pendingSegments() {
            guard !skippedSegments.contains(segment.lastPathComponent) else { continue }
            guard Self.fileSize(segment) <= storedByteLimit,
                  let raw = try? Data(contentsOf: segment),
                  let body = GzipEncoding.gzipped(raw) else {
                quarantine(segment, reason: "unreadable or over storage limit")
                continue
            }
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

            guard let response = try? await destination.send(request).1,
                  let status = (response as? HTTPURLResponse)?.statusCode else {
                // Host unreachable. Keep the segment and try again next pass.
                return uploaded
            }
            guard (200..<300).contains(status) else {
                logger.error("app log upload rejected with \(status, privacy: .public)")
                return uploaded
            }
            try? FileManager.default.removeItem(at: segment)
            uploaded += 1
        }
        return uploaded
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
