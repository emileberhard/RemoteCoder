import Foundation

extension ProviderAccountSnapshot {
    var usageNotice: String? {
        if state != .ready { return state.title }
        return stale ? "Last known usage" : nil
    }

    var notReadyReason: String? {
        guard state != .ready else { return nil }
        return error ?? (stale ? nil : state.title)
    }

    var usageStatus: String {
        usageNotice ?? [provider.displayName, plan?.capitalized].compactMap { $0 }.joined(separator: " · ")
    }

    var usageRows: [CodexUsageLimitRow] {
        let now = Date.now
        return windows.map { window in
            let kind: UsageWindowKind
            if window.model?.lowercased().contains("fable") == true {
                kind = .fable
            } else if window.model != nil {
                kind = .other
            } else {
                kind = switch window.durationMinutes {
                case 300: .fiveHour
                case 10080: .weekly
                default: .other
                }
            }
            return CodexUsageLimitRow(id: window.id, title: kind == .other ? window.label : kind.label,
                usedPercent: 100 - window.remainingPercent, kind: kind,
                isStale: stale || state != .ready,
                resetText: window.resetText(now: now, calendar: .autoupdatingCurrent),
                runOutWarning: kind == .fiveHour ? observedDate.flatMap { UsageRunOutWarning(window: window, observedAt: $0, now: now) } : nil)
        }
    }
}

extension AccountUsageWindow {
    func resetText(now: Date, calendar: Calendar) -> String? {
        guard let resetDate else { return nil }
        let style = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: resetDate)).day
        let moment = switch days {
        case 0?: resetDate.formatted(style.hour().minute())
        case .some(1...6): resetDate.formatted(style.weekday(.abbreviated).hour().minute())
        default: resetDate.formatted(style.day().month(.abbreviated))
        }
        return "Resets \(moment)"
    }
}
