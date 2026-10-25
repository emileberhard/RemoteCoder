import Foundation
import OSLog
import Synchronization

struct AppLogger: Sendable {
    static let subsystem = "RemoteCoder"

    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppLogSink.shared.append(record("info", message))
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        AppLogSink.shared.append(record("notice", message))
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppLogSink.shared.append(record("error", message))
    }

    func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        AppLogSink.shared.append(record("fault", message))
    }

    private func record(_ level: String, _ message: String) -> AppLogRecord {
        var thread: UInt64 = 0
        pthread_threadid_np(nil, &thread)
        return AppLogRecord(ts: .now, level: level, subsystem: Self.subsystem, category: category,
                            message: message, thread: thread)
    }
}

struct AppLogBatch: Sendable {
    let records: [AppLogRecord]
    let dropped: Int
    let droppedBytes: Int
}

final class AppLogSink: Sendable {
    static let shared = AppLogSink()

    private struct State {
        var records: [AppLogRecord] = []
        var bytes = 0
        var dropped = 0
        var droppedBytes = 0
        var signaled = false
        var onHighWater: (@Sendable () -> Void)?
    }

    private let byteLimit: Int
    private let state = Mutex(State())

    init(byteLimit: Int = 2 * 1024 * 1024) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    func setHighWaterHandler(_ handler: (@Sendable () -> Void)?) {
        let signal = state.withLock { state in
            state.onHighWater = handler
            return pendingSignal(&state)
        }
        signal?()
    }

    func append(_ record: AppLogRecord) {
        let size = Self.size(of: record)
        let signal: (@Sendable () -> Void)? = state.withLock { state in
            guard size <= byteLimit / 8 else {
                state.dropped += 1
                state.droppedBytes += size
                return nil
            }
            state.records.append(record)
            state.bytes += size
            if state.bytes > byteLimit { evict(&state) }
            return pendingSignal(&state)
        }
        signal?()
    }

    func take() -> AppLogBatch {
        state.withLock { state in
            let batch = AppLogBatch(records: state.records, dropped: state.dropped, droppedBytes: state.droppedBytes)
            state.records.removeAll(keepingCapacity: true)
            state.bytes = 0
            state.dropped = 0
            state.droppedBytes = 0
            state.signaled = false
            return batch
        }
    }

    func restore(_ records: [AppLogRecord]) {
        state.withLock { state in
            state.records = records + state.records
            state.bytes += records.reduce(0) { $0 + Self.size(of: $1) }
            state.signaled = true
            if state.bytes > byteLimit { evict(&state) }
        }
    }

    private func pendingSignal(_ state: inout State) -> (@Sendable () -> Void)? {
        guard !state.signaled, state.bytes > byteLimit / 2, let handler = state.onHighWater else { return nil }
        state.signaled = true
        return handler
    }

    private func evict(_ state: inout State) {
        let target = byteLimit * 3 / 4
        var count = 0
        var freed = 0
        while count < state.records.count, state.bytes - freed > target {
            freed += Self.size(of: state.records[count])
            count += 1
        }
        state.records.removeFirst(count)
        state.bytes -= freed
        state.dropped += count
        state.droppedBytes += freed
    }

    private static func size(of record: AppLogRecord) -> Int {
        record.message.utf8.count + record.category.utf8.count + 96
    }
}
