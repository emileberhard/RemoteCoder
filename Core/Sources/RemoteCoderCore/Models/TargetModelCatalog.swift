import Foundation

@MainActor
struct TargetModelCatalog {
    let service: CodexModelCatalogService
    let preferences: ModelPickerPreferences
    let defaults: UserDefaults

    var preferredProvider: AgentProvider? {
        NewChatModelResolution.provider(preferredID: NewChatDefaults.preferredModelID(defaults: defaults), providers: Set(AgentProvider.allCases), catalog: service.catalog)
    }

    func options(for provider: AgentProvider) -> [ModelOption] {
        let gateway = service.catalog?.visibleOptions(preferences.codexModelVisibility).filter { $0.provider == provider && (provider != .claude || $0.modelProvider != nil) } ?? []
        return provider == .claude
            ? ClaudeModelCatalog.families(in: service.catalog).filter { preferences.claudeModelVisibility.isVisible(id: $0.id) } + gateway
            : gateway
    }

    func isVisible(_ model: ModelOption, using visibility: ModelVisibility) -> Bool {
        if let entry = service.catalog?.entry(for: model.id), entry.option.provider == model.provider,
           model.provider != .claude || model.modelProvider != nil {
            return visibility.isVisible(entry)
        }
        return model.provider == .claude && visibility.isVisible(id: ClaudeModelCatalog.canonicalModelID(model.id))
    }

    func pickerOptions(including selection: ModelOption, threadModelProvider: ThreadModelProvider?) -> [ModelOption] {
        let modelProvider = threadModelProvider.map(\.externalID) ?? selection.modelProvider?.id
        let options = options(for: selection.provider).filter { $0.modelProvider?.id == modelProvider }
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
        let preferredID = NewChatDefaults.preferredModelID(defaults: defaults)
        let preferredExternal = preferredID.flatMap { service.catalog?.entry(for: $0) }
            .map { $0.option.modelProvider != nil && preferences.codexModelVisibility.isVisible($0) } ?? false
        if provider == nil, !preferredExternal, let working = health?.workingProviders, working.count < AgentProvider.allCases.count,
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
            let provider = NewChatModelResolution.provider(preferredID: preferredID, providers: providers, catalog: service.catalog)
            return provider == .codex && service.catalog == nil ? .listNotLoaded : .notOffered
        }
        return .available(model)
    }

    func provider(forModelID id: String) -> AgentProvider {
        service.catalog?.entry(for: id)?.option.provider ?? service.catalog?.entry(for: ClaudeModelCatalog.canonicalModelID(id))?.option.provider ?? AgentProvider.provider(forModelID: id)
    }

    func configured(id: String) -> NewChatModelLookup {
        if let option = service.catalog?.entry(for: id)?.option { return .available(option) }
        if let option = ClaudeModelCatalog.model(for: id, in: service.catalog) { return .available(option) }
        return service.catalog == nil ? .listNotLoaded : .notOffered
    }

    func option(id: String, threadID: String, modelProvider: ThreadModelProvider?, effort: String?, fastMode: Bool) -> ModelOption? {
        guard !id.isEmpty else { return nil }
        let provider = AgentProvider.provider(forThreadID: threadID)
        if let option = service.catalog?.entry(for: id)?.option {
            if option.provider == provider, modelProvider == nil || option.modelProvider?.id == modelProvider?.externalID {
                return option
            }
            if let route = modelProvider?.externalID, option.modelProvider?.id == route {
                return ModelOption(id: option.id, displayName: option.displayName, reasoningEfforts: option.reasoningEfforts,
                    supportsFastMode: option.supportsFastMode, supportsDaybreakBlue: option.supportsDaybreakBlue,
                    acceptsImages: option.acceptsImages, provider: provider, modelProvider: option.modelProvider, isListed: option.isListed)
            }
        }
        if provider == .claude, modelProvider?.externalID == nil,
           let option = ClaudeModelCatalog.model(for: id, in: service.catalog) { return option }
        return .unlisted(id: id, modelProvider: modelProvider?.modelProvider,
                         reportedEffort: effort.flatMap(ReasoningEffort.init(rawValue:)), reportedFastMode: fastMode, provider: provider)
    }
}
