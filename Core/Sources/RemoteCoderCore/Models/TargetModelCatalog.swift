import Foundation

@MainActor
struct TargetModelCatalog {
    let service: CodexModelCatalogService
    let preferences: ModelPickerPreferences
    let defaults: UserDefaults

    var preferredProvider: AgentProvider? {
        NewChatModelResolution.provider(preferredID: NewChatDefaults.preferredModelID(defaults: defaults), providers: Set(AgentProvider.allCases))
    }

    func options(for provider: AgentProvider) -> [ModelOption] {
        switch provider {
        case .claude: return ClaudeModelCatalog.models.filter { preferences.claudeModelVisibility.isVisible(id: $0.id) }
        case .codex: return service.catalog?.visibleOptions(preferences.codexModelVisibility) ?? []
        }
    }

    func isVisible(_ model: ModelOption, using visibility: ModelVisibility) -> Bool {
        switch model.provider {
        case .claude: return visibility.isVisible(id: ClaudeModelCatalog.canonicalModelID(model.id))
        case .codex: return service.catalog?.entry(for: model.id).map(visibility.isVisible) ?? false
        }
    }

    func pickerOptions(including selection: ModelOption) -> [ModelOption] {
        let options = options(for: selection.provider).filter { $0.modelProvider == selection.modelProvider }
        return options.contains { $0.id == selection.id } ? options : options + [selection]
    }

    func newChatUnavailableReason(for provider: AgentProvider?) -> String {
        if (provider ?? preferredProvider) == .claude { return "No Claude Code models are shown. Choose models in Settings." }
        if service.catalog == nil {
            if service.isRefreshing { return "Loading Codex models…" }
            return service.refreshError.map { "Codex models couldn't load: \($0)" } ?? "Codex models haven't loaded yet."
        }
        return "No Codex models are shown. Choose models in Settings."
    }

    func defaultModel(for provider: AgentProvider) -> ModelOption? {
        NewChatModelResolution.model(preferredID: nil, codex: service.catalog,
                                     codexVisibility: preferences.codexModelVisibility,
                                     claudeVisibility: preferences.claudeModelVisibility,
                                     providers: [provider])
    }

    func newChatDefault(for provider: AgentProvider?, health: ProviderHealth?) -> NewChatModelLookup {
        if provider == nil, let working = health?.workingProviders, working.count < AgentProvider.allCases.count,
           case .available(let model) = newChatDefault(among: working) {
            return .available(model)
        }
        return newChatDefault(among: provider.map { [$0] } ?? Set(AgentProvider.allCases))
    }

    private func newChatDefault(among providers: Set<AgentProvider>) -> NewChatModelLookup {
        let preferredID = NewChatDefaults.preferredModelID(defaults: defaults)
        guard let model = NewChatModelResolution.model(
            preferredID: preferredID,
            codex: service.catalog, codexVisibility: preferences.codexModelVisibility,
            claudeVisibility: preferences.claudeModelVisibility, providers: providers
        ) else {
            let provider = NewChatModelResolution.provider(preferredID: preferredID, providers: providers)
            return provider == .codex && service.catalog == nil ? .listNotLoaded : .notOffered
        }
        return .available(model)
    }

    func configured(id: String) -> NewChatModelLookup {
        let provider = AgentProvider.provider(forModelID: id)
        switch provider {
        case .claude:
            return ClaudeModelCatalog.model(for: id).map(NewChatModelLookup.available) ?? .notOffered
        case .codex:
            guard let catalog = service.catalog else { return .listNotLoaded }
            return catalog.entry(for: id).map { .available($0.option) } ?? .notOffered
        }
    }

    func option(id: String, threadID: String, effort: String?, fastMode: Bool) -> ModelOption? {
        switch AgentProvider.provider(forThreadID: threadID) {
        case .claude:
            return ClaudeModelCatalog.model(for: id)
        case .codex:
            guard !id.isEmpty else { return nil }
            return service.catalog?.entry(for: id)?.option
                ?? .unlisted(id: id, reportedEffort: effort.flatMap(ReasoningEffort.init(rawValue:)), reportedFastMode: fastMode)
        }
    }
}
