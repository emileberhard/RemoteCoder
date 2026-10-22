import Foundation

struct UsageRunOutWarning: Hashable, Sendable {
    static let maximumRemainingPercent = 60.0
    static let mostSevereLead: TimeInterval = 2 * 60 * 60

    let lead: TimeInterval

    var severity: Double { min(1, lead / Self.mostSevereLead) }

    init?(lead: TimeInterval) {
        guard lead > 0 else { return nil }
        self.lead = lead
    }

    init?(window: AccountUsageWindow, observedAt: Date, now: Date) {
        guard let minutes = window.durationMinutes, minutes > 0, let reset = window.resetDate, now < reset else { return nil }
        let used = min(100, max(0, window.usedPercent))
        let remaining = 100 - used
        let elapsed = observedAt.timeIntervalSince(reset.addingTimeInterval(-Double(minutes) * 60))
        guard remaining < Self.maximumRemainingPercent, elapsed > 0 else { return nil }
        let runOut = observedAt.addingTimeInterval(remaining * elapsed / used)
        self.init(lead: reset.timeIntervalSince(runOut))
    }
}
