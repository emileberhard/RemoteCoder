import Foundation
import Observation

@Observable @MainActor
final class ModelPickerPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: ((_ provider: AgentProvider, _ previousModelVisibility: ModelVisibility) -> Void)?
    private var codexEfforts: ReasoningEffortVisibility
    private var claudeEfforts: ReasoningEffortVisibility
    private(set) var codexModelVisibility: ModelVisibility
    private(set) var claudeModelVisibility: ModelVisibility

    init(defaults: UserDefaults) {
        self.defaults = defaults
        codexEfforts = .load(for: .codex, defaults: defaults)
        claudeEfforts = .load(for: .claude, defaults: defaults)
        codexModelVisibility = .load(for: .codex, defaults: defaults)
        claudeModelVisibility = .load(for: .claude, defaults: defaults)
    }

    static let syncedKeys = Set(AgentProvider.allCases.flatMap {
        [ModelVisibility.key(for: $0), ReasoningEffortVisibility.key(for: $0)]
    })

    func reload() {
        for provider in AgentProvider.allCases {
            let previous = modelVisibility(for: provider)
            let efforts = ReasoningEffortVisibility.load(for: provider, defaults: defaults)
            let visibility = ModelVisibility.load(for: provider, defaults: defaults)
            guard efforts != self.efforts(for: provider) || visibility != previous else { continue }
            switch provider {
            case .codex:
                codexEfforts = efforts
                codexModelVisibility = visibility
            case .claude:
                claudeEfforts = efforts
                claudeModelVisibility = visibility
            }
            onChange?(provider, previous)
        }
    }

    func reasoningEfforts(for model: ModelOption) -> [ReasoningEffort] {
        efforts(for: model.provider).efforts(for: model)
    }

    func clamped(_ selection: ReasoningSelection, for model: ModelOption) -> ReasoningSelection {
        efforts(for: model.provider).clamped(selection, for: model)
    }

    func isVisible(_ effort: ReasoningEffort, for provider: AgentProvider) -> Bool {
        efforts(for: provider).contains(effort)
    }

    func setVisible(_ effort: ReasoningEffort, _ isVisible: Bool, for provider: AgentProvider) {
        var updated = efforts(for: provider)
        updated.setVisible(effort, isVisible)
        guard updated != efforts(for: provider) else { return }
        switch provider {
        case .codex: codexEfforts = updated
        case .claude: claudeEfforts = updated
        }
        defaults.set(updated.rawValue, forKey: ReasoningEffortVisibility.key(for: provider))
        onChange?(provider, modelVisibility(for: provider))
    }

    func modelVisibility(for provider: AgentProvider) -> ModelVisibility {
        provider == .codex ? codexModelVisibility : claudeModelVisibility
    }

    func setModelVisible(_ isVisible: Bool, for entry: CodexModelCatalog.Entry) {
        setModelVisible(isVisible, id: entry.id, provider: .codex, defaultVisibility: !entry.isHiddenUpstream)
    }

    func setClaudeModelVisible(_ isVisible: Bool, id: String) {
        setModelVisible(isVisible, id: ClaudeModelCatalog.canonicalModelID(id), provider: .claude, defaultVisibility: true)
    }

    private func setModelVisible(_ isVisible: Bool, id: String, provider: AgentProvider, defaultVisibility: Bool) {
        let previous = modelVisibility(for: provider)
        var updated = previous
        updated.setVisible(isVisible, id: id, defaultVisibility: defaultVisibility)
        guard updated != previous else { return }
        switch provider {
        case .codex: codexModelVisibility = updated
        case .claude: claudeModelVisibility = updated
        }
        defaults.set(updated.rawValue, forKey: ModelVisibility.key(for: provider))
        onChange?(provider, previous)
    }

    private func efforts(for provider: AgentProvider) -> ReasoningEffortVisibility {
        provider == .codex ? codexEfforts : claudeEfforts
    }
}
