import Foundation

enum UsageWindowKind: Int, CaseIterable, Hashable, Sendable {
    case fiveHour, weekly, fable, other
}

struct CodexUsageLimitRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let usedPercent: Int
    var remainingPercent: Int { 100 - usedPercent }
    let kind: UsageWindowKind
    var isStale = false
    let resetText: String?
    var runOutWarning: UsageRunOutWarning? = nil
}

extension UsageWindowKind {
    var label: String {
        switch self { case .weekly: "Weekly"; case .fiveHour: "5-hour"; case .fable: "Fable weekly"; case .other: "Limit" }
    }
}
