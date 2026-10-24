import Foundation

struct CodexModelCatalog: Equatable, Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let option: ModelOption
        let summary: String
        let isHiddenUpstream: Bool
        let isUpstreamDefault: Bool

        var id: String { option.id }
    }

    let entries: [Entry]
    let fetchedAt: Date

    init(models: [CodexAppServerV2.Model], fetchedAt: Date) {
        var seen = Set<String>()
        entries = models.compactMap { model in
            guard seen.insert(model.model).inserted else { return nil }
            let efforts = Set(model.supportedReasoningEfforts.compactMap {
                ReasoningEffort(rawValue: $0.reasoningEffort.rawValue)
            })
            let supportsFastMode = (model.serviceTiers.map(\.id) + model.additionalSpeedTiers)
                .contains { CodexAppServerV2.ServiceTier(wireValue: $0) == .fast }
            return Entry(
                option: ModelOption(
                    id: model.model,
                    displayName: model.displayName,
                    reasoningEfforts: ReasoningEffort.allCases.filter(efforts.contains),
                    supportsFastMode: supportsFastMode,
                    supportsDaybreakBlue: model.availableAccessPrograms?.cyber.contains("daybreakBlue") == true,
                    acceptsImages: model.inputModalities.contains(.image),
                    provider: .codex,
                    modelProvider: model.modelProvider,
                    isListed: true
                ),
                summary: model.description,
                isHiddenUpstream: model.hidden,
                isUpstreamDefault: model.isDefault
            )
        }
        self.fetchedAt = fetchedAt
    }

    func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func visibleOptions(_ visibility: ModelVisibility) -> [ModelOption] {
        entries.filter(visibility.isVisible).map(\.option)
    }
}

extension ModelVisibility {
    func isVisible(_ entry: CodexModelCatalog.Entry) -> Bool {
        isVisible(id: entry.id, defaultVisibility: !entry.isHiddenUpstream)
    }

    mutating func setVisible(_ isVisible: Bool, for entry: CodexModelCatalog.Entry) {
        setVisible(isVisible, id: entry.id, defaultVisibility: !entry.isHiddenUpstream)
    }
}

enum NewChatModelLookup: Equatable {
    case available(ModelOption)
    case hostUnavailable(AgentProvider)
    case listNotLoaded
    case notOffered

    var model: ModelOption? {
        guard case .available(let model) = self else { return nil }
        return model
    }
}

enum NewChatModelResolution {
    static func provider(preferredID: String?, providers: Set<AgentProvider>) -> AgentProvider? {
        let preferred = preferredID.map(AgentProvider.provider(forModelID:)) ?? .codex
        return providers.contains(preferred) ? preferred : AgentProvider.allCases.first(where: providers.contains)
    }

    static func model(
        preferredID: String?,
        codex: CodexModelCatalog?,
        codexVisibility: ModelVisibility,
        claudeVisibility: ModelVisibility,
        providers: Set<AgentProvider>
    ) -> ModelOption? {
        let preferredClaude = preferredID.flatMap(ClaudeModelCatalog.model(for:))
        switch provider(preferredID: preferredID, providers: providers) {
        case .claude:
            let visible = ClaudeModelCatalog.models.filter { claudeVisibility.isVisible(id: $0.id) }
            return visible.first { $0.id == preferredClaude?.id } ?? visible.first
        case .codex:
            guard let codex else { return nil }
            let visible = codex.entries.filter(codexVisibility.isVisible)
            return (visible.first { $0.id == preferredID }
                ?? visible.first { $0.id == NewChatDefaults.initialCodexModelID }
                ?? visible.first(where: \.isUpstreamDefault)
                ?? visible.first)?.option
        case nil:
            return nil
        }
    }
}
