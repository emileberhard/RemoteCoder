import Foundation

/// Scheduling after an attempt is separate from deciding whether data is stale.
/// No successful timestamp (or an old one) means a failed/in-flight attempt and
/// gets a bounded retry, not a tight loop. Interactive refresh still runs now.
enum HistoryRefreshTiming {
    static let maximumStaleness: TimeInterval = 15

    static func delay(after lastSuccess: Date?, now: Date) -> Duration {
        guard let lastSuccess else { return .seconds(maximumStaleness) }
        let remaining = maximumStaleness - now.timeIntervalSince(lastSuccess)
        return .seconds(remaining > 0 ? min(remaining, maximumStaleness) : maximumStaleness)
    }
}
