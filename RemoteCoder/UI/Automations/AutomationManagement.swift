import Foundation
import Observation

/// One shared inventory per physical authority. Settings drafts have stable
/// workspace ownership, while this owner never queues mutations.
@MainActor @Observable
final class AutomationManagement {
    let hostID: UUID
    let hostName: String
    let gateway: GatewayClient
    private var inventories: [AutomationInventoryScope: AutomationInventory] = Dictionary(uniqueKeysWithValues:
        AutomationInventoryFilter.allCases.map { (AutomationInventoryScope(filter: $0, search: ""), AutomationInventory()) })
    func cachedInventory(for filter: AutomationInventoryFilter, search: String = "") -> AutomationInventory? {
        inventories[AutomationInventoryScope(filter: filter, search: search)]
    }
    private func inventory(for scope: AutomationInventoryScope) -> AutomationInventory {
        if let inventory = inventories[scope] { inventory.accessedAt = .now; return inventory }
        if inventories.count >= 8, let oldest = inventories.min(by: { $0.value.accessedAt < $1.value.accessedAt }) {
            oldest.value.generation = UUID()
            inventories.removeValue(forKey: oldest.key)
        }
        let inventory = AutomationInventory(); inventories[scope] = inventory
        return inventory
    }
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var managedSourceIDs: [String] = []
    private(set) var refreshedAt: Date?
    private(set) var health: String?
    private(set) var error: String?
    private(set) var isAvailable = false
    private static let pageSize = 50
    private static let maximumRows = 500

    init(host: GatewayHostConfiguration, gateway: GatewayClient) {
        hostID = host.id; hostName = host.displayName; self.gateway = gateway
    }

    func connectivityChanged(_ connected: Bool) {
        connectionGeneration = UUID()
        isAvailable = false
        if !connected { error = "The automation host is disconnected. Saved results and drafts are kept." }
        invalidateInventories()
    }

    @discardableResult func refreshCapabilities() async -> Bool {
        let generation = connectionGeneration
        do {
            let status = try await gateway.automationStatus()
            guard try status.value().supportsManagement else { throw AutomationManagementError.unsupported }
            let preparedHealth = await Self.healthDescription(status.health)
            try Task.checkCancellation()
            guard connectionGeneration == generation else { return false }
            isAvailable = true; health = preparedHealth; error = nil
            return true
        } catch is CancellationError { return false }
        catch {
            guard connectionGeneration == generation else { return false }
            isAvailable = false; self.error = error.localizedDescription
            return false
        }
    }

    func refresh(filter: AutomationInventoryFilter? = nil, search: String = "", append: Bool = false, force: Bool = false) async {
        let selected = filter ?? .active
        let inventory = inventory(for: AutomationInventoryScope(filter: selected, search: search))
        if force { inventory.generation = UUID(); inventory.isRefreshing = false }
        guard !inventory.isRefreshing, !append || inventory.hasMore else { return }
        let token = UUID(); inventory.generation = token
        inventory.isRefreshing = true
        defer { if token == inventory.generation { inventory.isRefreshing = false } }
        let offset = append ? inventory.nextOffset : 0
        do {
            guard await refreshCapabilities() else { return }
            let result = try await gateway.listAutomations(AutomationRequest(
                includeRemoved: selected == .all || selected == .removed,
                state: selected == .all ? nil : selected.rawValue, search: search.isEmpty ? nil : search, limit: Self.pageSize, offset: offset))
            let list = try result.value()
            let preparedItems = await AutomationPresentation.prepare(list.items)
            let preparedHealth = await Self.healthDescription(result.health)
            try Task.checkCancellation()
            guard inventory.generation == token else { return }
            if append {
                var seen = Set<String>()
                inventory.items = Array((inventory.items + preparedItems).filter { seen.insert($0.id).inserted }.suffix(Self.maximumRows))
            } else { inventory.items = preparedItems }
            inventory.nextOffset = offset + list.items.count
            inventory.hasMore = list.items.count == Self.pageSize
            inventory.refreshedAt = .now
            refreshedAt = .now; health = preparedHealth; error = nil; isAvailable = true
        } catch is CancellationError {
        } catch {
            guard inventory.generation == token else { return }
            self.error = error.localizedDescription
            isAvailable = false
        }
    }

    func detail(_ id: String, revision: Int? = nil, offset: Int = 0) async throws -> AutomationDetail {
        let detail = try await gateway.showAutomation(AutomationRequest(id: id, targetRevision: revision, limit: Self.pageSize, offset: offset)).value()
        if revision == nil, detail.managed == true {
            managedSourceIDs.removeAll { $0 == id }; managedSourceIDs.append(id)
            if managedSourceIDs.count > 128 { managedSourceIDs.removeFirst() }
        }
        return detail
    }
    func history(_ id: String, offset: Int = 0) async throws -> AutomationHistory {
        try await gateway.automationHistory(AutomationRequest(id: id, limit: Self.pageSize, offset: offset)).value()
    }
    func runDetail(_ id: String, outputOffset: Int? = nil) async throws -> AutomationRunDetail {
        try await gateway.automationRunDetail(AutomationRequest(id: "run/\(id)", outputOffset: outputOffset, outputLimit: 32768)).value()
    }
    func mutate(_ mutation: AutomationMutation) async throws -> JSONValue {
        guard isAvailable else { throw AutomationManagementError.unavailable }
        if mutation.operation != .run, let id = mutation.request.id,
           managedSourceIDs.contains(id) || inventories.values.contains(where: { $0.items.contains { $0.id == id && $0.managed == true } }) {
            throw AutomationManagementError.managedSource
        }
        let envelope: AutomationEnvelope<JSONValue>
        switch mutation.operation {
        case .save: envelope = try await gateway.setAutomation(mutation.request)
        case .remove: envelope = try await gateway.removeAutomation(mutation.request)
        case .restore: envelope = try await gateway.restoreAutomation(mutation.request)
        case .run: envelope = try await gateway.runAutomation(mutation.request)
        }
        let value = try envelope.value()
        await refreshCachedInventories()
        return value
    }
    private func invalidateInventories() {
        for inventory in inventories.values { inventory.generation = UUID(); inventory.isRefreshing = false }
    }
    func refreshCachedInventories() async {
        let scopes = Array(inventories.keys)
        // Invalidate before the first suspension: a pre-mutation response cannot
        // republish old inventory while a different scope refreshes first.
        invalidateInventories()
        for scope in scopes { await refresh(filter: scope.filter, search: scope.search, force: true) }
    }
    @concurrent private static func healthDescription(_ value: JSONValue?) async -> String? {
        guard let fields = value?.objectValue else { return nil }
        if let state = fields["status"]?.stringValue, state != "healthy" && state != "ok" {
            let messages = fields["issues"]?.arrayValue?.compactMap { $0.objectValue?["message"]?.stringValue } ?? []
            let issues = messages.prefix(10).joined(separator: "\n")
            return "Service health: \(state)" + (issues.isEmpty ? "" : "\n" + issues)
        }
        if let message = fields["message"]?.stringValue { return message }
        if let error = fields["error"]?.stringValue { return error }
        return nil
    }
}

struct AutomationInventoryScope: Hashable {
    let filter: AutomationInventoryFilter
    let search: String
}

@MainActor @Observable
final class AutomationInventory {
    var items: [AutomationSummary] = []
    var isRefreshing = false
    var hasMore = false
    var refreshedAt: Date?
    @ObservationIgnored var accessedAt = Date.now
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var nextOffset = 0
}

enum AutomationManagementError: LocalizedError {
    case unavailable, unsupported, managedSource
    var errorDescription: String? {
        switch self {
        case .unavailable: "The automation service is unavailable. Your draft is kept; refresh before saving."
        case .managedSource: "This source is managed by the service. Change its owning automation instead."
        case .unsupported: "This gateway does not support automation management yet. Update its service and gateway to manage automations."
        }
    }
}
