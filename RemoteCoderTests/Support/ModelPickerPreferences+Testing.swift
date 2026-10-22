@testable import RemoteCoder

extension ModelPickerPreferences {
    func show(only shown: [ReasoningEffort], for provider: AgentProvider = .codex) {
        for effort in ReasoningEffort.allCases { setVisible(effort, shown.contains(effort), for: provider) }
    }
}
