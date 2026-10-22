import Foundation

struct ReasoningEffortVisibility: RawRepresentable, Equatable {
    static let codexKey = "reasoning.visibleLevels.codex"
    static let claudeKey = "reasoning.visibleLevels.claude"
    static let defaultValue = Self(rawValue: "low,medium,high,xhigh")

    private var visible: Set<ReasoningEffort>

    init(rawValue: String) {
        visible = Set(rawValue.split(separator: ",").compactMap { ReasoningEffort(rawValue: String($0)) })
    }

    var rawValue: String {
        ReasoningEffort.allCases.filter(visible.contains).map(\.rawValue).joined(separator: ",")
    }

    static func key(for provider: AgentProvider) -> String {
        provider == .codex ? codexKey : claudeKey
    }

    static func load(for provider: AgentProvider, defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: key(for: provider)) ?? defaultValue.rawValue)
    }

    func contains(_ effort: ReasoningEffort) -> Bool { visible.contains(effort) }

    mutating func setVisible(_ effort: ReasoningEffort, _ isVisible: Bool) {
        if isVisible { visible.insert(effort) } else { visible.remove(effort) }
    }

    func efforts(for model: ModelOption) -> [ReasoningEffort] {
        model.isListed ? model.reasoningEfforts.filter(visible.contains) : model.reasoningEfforts
    }

    func clamped(_ selection: ReasoningSelection, for model: ModelOption) -> ReasoningSelection {
        guard let effort = selection.effort else { return .automatic }
        let ranked = ReasoningEffort.allCases.enumerated()
        guard let desired = ranked.first(where: { $0.element == effort })?.offset else { return selection }
        let available = Set(efforts(for: model))
        let nearest = ranked.filter { available.contains($0.element) }.min {
            let lhs = abs($0.offset - desired)
            let rhs = abs($1.offset - desired)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }
        return nearest.map { .effort($0.element) } ?? .automatic
    }
}
