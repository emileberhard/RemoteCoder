import Foundation

enum ConversationSidebarDate {
    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(60 * 24): return "\(minutes / 60)h"
        case ..<(60 * 24 * 7): return "\(minutes / (60 * 24))d"
        case ..<(60 * 24 * 365): return "\(minutes / (60 * 24 * 7))w"
        default: return "\(minutes / (60 * 24 * 365))y"
        }
    }

    static func label(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .min
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch daysAgo {
        case 0:
            return date.formatted(style.hour().minute())
        case 1:
            return "Yesterday"
        case 2...6:
            return date.formatted(style.weekday(.wide))
        default:
            let dayAndMonth = style.day().month(.abbreviated)
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return date.formatted(sameYear ? dayAndMonth : dayAndMonth.year())
        }
    }
}

final class ConversationSidebarDateCache {
    private struct Context: Equatable {
        let day: Date
        let calendar: Calendar
        let locale: Locale
    }

    private var context: Context?
    private var labels: [Date: String] = [:]

    func labeler(now: Date, calendar: Calendar, locale: Locale) -> (Date) -> String {
        let current = Context(day: calendar.startOfDay(for: now), calendar: calendar, locale: locale)
        if current != context {
            labels.removeAll(keepingCapacity: true)
            context = current
        }
        return { [self] date in
            if let label = labels[date] { return label }
            let label = ConversationSidebarDate.label(for: date, now: now, calendar: calendar, locale: locale)
            if labels.count == 2_048 { labels.removeAll(keepingCapacity: true) }
            labels[date] = label
            return label
        }
    }
}
