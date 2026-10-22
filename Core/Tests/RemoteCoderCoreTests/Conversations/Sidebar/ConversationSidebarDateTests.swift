import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationSidebarDateTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func label(_ date: Date) -> String {
        ConversationSidebarDate.label(for: date, now: self.date(2026, 10, 1, 23, 30), calendar: calendar, locale: locale)
    }

    @Test func recentDatesUseTheShortestUnambiguousLabel() {
        #expect(label(date(2026, 10, 1, 0, 5)) == "12:05\u{202F}AM")
        #expect(label(date(2026, 9, 30, 23, 59)) == "Yesterday")
        #expect(label(date(2026, 9, 29)) == "Tuesday")
        #expect(label(date(2026, 9, 25)) == "Friday")
    }

    @Test func olderDatesNameTheDayAndOnlyAddAYearWhenItDiffers() {
        #expect(label(date(2026, 9, 24)) == "Sep 24")
        #expect(label(date(2025, 12, 31)) == "Dec 31, 2025")
    }

    @Test func aFutureTimestampFromClockSkewIsNotCalledToday() {
        #expect(label(date(2026, 10, 2, 0, 10)) == "Oct 2")
    }

    @Test func ageUsesTheLargestWholeUnit() {
        let now = date(2026, 10, 1, 23, 30)
        func age(_ seconds: TimeInterval) -> String { ConversationSidebarDate.age(of: now.addingTimeInterval(-seconds), now: now) }
        #expect(age(59) == "now")
        #expect(age(-600) == "now")
        #expect(age(2 * 60 + 59) == "2m")
        #expect(age(59 * 60 + 59) == "59m")
        #expect(age(3 * 3_600) == "3h")
        #expect(age(23 * 3_600 + 3_599) == "23h")
        #expect(age(2 * 86_400) == "2d")
        #expect(age(6 * 86_400 + 86_399) == "6d")
        #expect(age(15 * 86_400) == "2w")
        #expect(age(400 * 86_400) == "1y")
    }
}
