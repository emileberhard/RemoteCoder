import Foundation

extension ChatWorkspaceModel {
    /// The gateway reports the physical authority independently of the presented chat.
    var automationAuthority: AutomationManagement? {
        let authorities = Set(settings.hosts.compactMap {
            model(for: $0.id)?.directories.information?.automationsAuthority
        })
        guard authorities.count == 1, let name = authorities.first,
              let host = automationExecutionHost(name) else { return nil }
        return model(for: host.id)?.hostServices.automations
    }

    var automationAuthorityIsConnected: Bool {
        guard let authority = automationAuthority else { return false }
        return model(for: authority.hostID)?.isGatewayConnected == true
    }

    func refreshAutomationModels(host: String) async {
        guard let host = automationExecutionHost(host), let target = model(for: host.id) else { return }
        await target.refreshCodexModels()
    }

    func automationExecutionHost(_ name: String) -> GatewayHostConfiguration? {
        AutomationHostResolver.resolve(name, hosts: settings.hosts.map(\.configuration), reportedHostnames:
            Dictionary(uniqueKeysWithValues: settings.hosts.compactMap { host in
                model(for: host.id)?.directories.information?.hostname.map { (host.id, $0) }
            }))
    }

    func automationModels(host: String, provider: String) -> [ModelOption] {
        guard let host = automationExecutionHost(host), let provider = AgentProvider(rawValue: provider) else { return [] }
        if provider == .claude { return ClaudeModelCatalog.models }
        guard let target = model(for: host.id) else { return [] }
        switch provider {
        case .codex: return target.codexModels.catalog?.entries.map(\.option) ?? []
        case .claude: return ClaudeModelCatalog.models
        }
    }

    func prepareAutomationConversation(_ route: AutomationExecutionRoute) async throws -> ConversationAddress {
        guard let host = automationExecutionHost(route.host) else { throw AutomationNavigationError.unavailable }
        let address = ConversationAddress(hostID: host.id, threadID: route.threadID)
        guard let target = model(for: address.hostID), !target.isRetired else { throw AutomationNavigationError.unavailable }
        await prepareAndRegister(target)
        try Task.checkCancellation()
        guard model(for: address.hostID) === target, target.isGatewayConnected else { throw AutomationNavigationError.unavailable }
        return address
    }

    func automationConversation(_ run: AutomationRunDetail) -> ConversationAddress? {
        guard let route = AutomationExecutionRoute(receipt: run.receipt),
              let host = automationExecutionHost(route.host) else { return nil }
        return ConversationAddress(hostID: host.id, threadID: route.threadID)
    }
}

enum AutomationNavigationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The execution host could not be prepared. Refresh its connection before opening this conversation." }
}
