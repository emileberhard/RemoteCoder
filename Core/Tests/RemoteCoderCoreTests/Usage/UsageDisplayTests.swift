import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct UsageDisplayTests {
    @Test func fiveHourWarningProjectsTheAverageDrainSinceTheWindowStarted() throws {
        let reset = try Date("2026-09-25T17:00:00+02:00", strategy: .iso8601)
        func warning(remaining: Double, observed: String, now: String? = nil) throws -> UsageRunOutWarning? {
            let window = AccountUsageWindow(id: "five", label: "5-hour", durationMinutes: 300, usedPercent: 100 - remaining,
                                            resetsAt: reset.timeIntervalSince1970, model: nil)
            let observedAt = try Date(observed, strategy: .iso8601)
            return UsageRunOutWarning(window: window, observedAt: observedAt, now: try now.map { try Date($0, strategy: .iso8601) } ?? observedAt)
        }
        let fiftyMinutesEarly = try #require(try warning(remaining: 40, observed: "2026-09-25T14:30:00+02:00"))
        #expect(abs(fiftyMinutesEarly.lead - 50 * 60) < 1)
        #expect(try warning(remaining: 60, observed: "2026-09-25T12:30:00+02:00") == nil)
        #expect(try warning(remaining: 0, observed: "2026-09-25T14:30:00+02:00")?.severity == 1)
        #expect(try warning(remaining: 49, observed: "2026-09-25T12:00:00+02:00") == nil)
        let unknownDuration = AccountUsageWindow(id: "five", label: "5-hour", durationMinutes: nil, usedPercent: 90,
                                                 resetsAt: reset.timeIntervalSince1970, model: nil)
        #expect(UsageRunOutWarning(window: unknownDuration, observedAt: reset.addingTimeInterval(-3600), now: reset.addingTimeInterval(-3600)) == nil)
        let barely = try #require(try warning(remaining: 49, observed: "2026-09-25T14:30:00+02:00"))
        #expect(abs(barely.lead - 2.5 * 3600 * (1 - 49.0 / 51)) < 1)
        #expect(barely.severity < 0.06)
        #expect(try warning(remaining: 51, observed: "2026-09-25T14:30:00+02:00") == nil)
        #expect(try warning(remaining: 61, observed: "2026-09-25T12:05:00+02:00") == nil)
        #expect(try warning(remaining: 59, observed: "2026-09-25T12:30:00+02:00")?.severity == 1)
        #expect(try warning(remaining: 49, observed: "2026-09-25T14:30:00+02:00", now: "2026-09-25T17:00:00+02:00") == nil)
        #expect(UsageRunOutWarning(lead: 3600)?.severity == 0.5)
        #expect(UsageRunOutWarning(lead: 0) == nil)
    }

    @Test func onlyTheFiveHourRowCarriesTheSampleWarning() {
        let now = Date.now.timeIntervalSince1970
        let sample = ProviderAccountSnapshot(
            id: "default-claude", provider: .claude, label: "Account", enabled: true, generation: 1, isDefault: true,
            identity: nil, plan: nil, state: .ready,
            windows: [
                .init(id: "five", label: "5-hour", durationMinutes: 300, usedPercent: 90, resetsAt: now + 3600, model: nil),
                .init(id: "week", label: "Weekly", durationMinutes: 10080, usedPercent: 99, resetsAt: now + 3600, model: nil)
            ], observedAt: now, stale: false, error: nil, activeTurns: 0, incomingCallRoutingId: nil
        )
        let rows = sample.usageRows
        #expect(rows.first { $0.kind == .fiveHour }?.runOutWarning != nil)
        #expect(rows.first { $0.kind == .weekly }?.runOutWarning == nil)
    }

    @Test func claudeReadinessNamesTheGatewayCauseAndKeepsAStaleCacheUnknown() {
        func claude(_ state: ProviderAccountSnapshot.State, stale: Bool, error: String?) -> ProviderAccountSnapshot {
            ProviderAccountSnapshot(id: "default-claude", provider: .claude, label: "Claude", enabled: true, generation: 1,
                                    isDefault: true, identity: nil, plan: nil, state: state, windows: [], observedAt: nil,
                                    stale: stale, error: error, activeTurns: 0, incomingCallRoutingId: nil)
        }
        #expect(claude(.ready, stale: false, error: nil).notReadyReason == nil)
        #expect(claude(.unavailable, stale: false, error: "llm-router key is not readable").notReadyReason == "llm-router key is not readable")
        #expect(claude(.unavailable, stale: true, error: "llm-router key is not readable").notReadyReason == "llm-router key is not readable")
        #expect(claude(.unavailable, stale: true, error: nil).notReadyReason == nil)
        #expect(claude(.unavailable, stale: false, error: nil).notReadyReason == "Unavailable")
    }

    @Test func resetTextNamesTheTimeTodayTheWeekdayThisWeekAndTheDateBeyond() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let now = try Date("2026-09-24T02:51:00+02:00", strategy: .iso8601)
        func reset(_ iso: String) throws -> String? {
            let resetsAt = try Date(iso, strategy: .iso8601).timeIntervalSince1970
            return AccountUsageWindow(id: "w", label: "Weekly", durationMinutes: 10080, usedPercent: 0, resetsAt: resetsAt, model: nil)
                .resetText(now: now, calendar: calendar)
        }
        #expect(try reset("2026-09-24T06:10:00+02:00") == "Resets 06:10")
        #expect(try reset("2026-09-28T17:00:00+02:00") == "Resets Mon 17:00")
        #expect(try reset("2026-10-01T00:16:00+02:00") == "Resets 1 Oct")
    }
}
