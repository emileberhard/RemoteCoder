import Foundation

struct ConversationActivity: Equatable {
    typealias State = CodexGatewayDaemon.ActivityState

    private struct Coverage: Equatable {
        let activeThreadIDs: Set<String>
        let external: External

        func state(for sessionID: String) -> State {
            if activeThreadIDs.contains(sessionID) { return .working }
            guard let external = coveredExternal(for: sessionID) else { return .unknown }
            return external.states[sessionID] ?? .idle
        }

        func coveredExternal(for sessionID: String) -> External? {
            guard AgentProvider.provider(forThreadID: sessionID) == .claude ? external.claudeAvailable : external.codexAvailable
            else { return nil }
            return external
        }
    }

    private struct External: Equatable {
        let states: [String: State]
        let owners: [String: CodexGatewayDaemon.ExternalActivity.SessionOwner]
        let waitingSince: [String: Int64]
        let claudeAvailable: Bool
        let codexAvailable: Bool
    }

    private let coverage: Coverage?
    private let agentOwners: [String: String]
    private let agentOwnerStates: [String: State]

    init(snapshot: CodexGatewayDaemon.ActiveTurnsResponse? = nil) {
        let coverage = snapshot.map { snapshot in
            Coverage(activeThreadIDs: Set(snapshot.activeTurns.map(\.threadId)), external:
                External(states: Dictionary(snapshot.externalActivity.sessions.map { ($0.threadId, $0.state) }, uniquingKeysWith: { first, _ in first }),
                         owners: Dictionary(snapshot.externalActivity.sessions.compactMap { session in session.owner.map { (session.threadId, $0) } },
                                            uniquingKeysWith: { first, second in first == .client ? first : second }),
                         waitingSince: Dictionary(snapshot.externalActivity.sessions.compactMap { session in
                             session.waitingSince.map { (session.threadId, $0) } }, uniquingKeysWith: max),
                         claudeAvailable: snapshot.externalActivity.claudeAvailable,
                         codexAvailable: snapshot.externalActivity.codexAvailable && snapshot.coverage.codex))
        }
        self.coverage = coverage
        agentOwners = snapshot?.agentOwners ?? [:]
        var ownerStates: [String: State] = [:]
        if let coverage {
            for (child, owner) in agentOwners {
                switch coverage.state(for: child) {
                case .working, .waiting: ownerStates[owner] = .working
                case .unknown:
                    if ownerStates[owner] == nil { ownerStates[owner] = .unknown }
                case .idle: break
                }
            }
        }
        agentOwnerStates = ownerStates
    }

    func childThreadIDs(of threadID: String) -> Set<String> {
        Set(agentOwners.lazy.filter { $0.value == threadID }.map(\.key))
    }

    var knownActiveThreadIDs: Set<String> {
        guard let coverage else { return [] }
        return coverage.activeThreadIDs.union(agentOwnerStates.compactMap { $0.value == .working ? $0.key : nil })
            .union(coverage.external.states.compactMap { $0.value == .working || $0.value == .waiting ? $0.key : nil })
    }

    func state(for sessionID: String, hasManagedTurn: Bool = false) -> State {
        if hasManagedTurn { return .working }
        let ownState = coverage?.state(for: sessionID) ?? .unknown
        switch agentOwnerStates[sessionID] {
        case .working: return .working
        case .unknown where ownState == .idle: return .unknown
        default: return ownState
        }
    }

    func waitingSince(for sessionID: String) -> Int64? {
        coverage?.coveredExternal(for: sessionID)?.waitingSince[sessionID]
    }

    func dispatchBlock(for sessionID: String?, hasManagedTurn: Bool = false) -> DispatchBlock? {
        guard let sessionID else { return nil }
        if hasManagedTurn || coverage?.activeThreadIDs.contains(sessionID) == true {
            return nil
        }
        guard let external = coverage?.coveredExternal(for: sessionID) else { return .unknown }
        switch external.owners[sessionID] {
        case .client: return .otherClient
        case .gateway: return nil
        case nil: break
        }
        switch external.states[sessionID] ?? .idle {
        case .idle: return nil
        case .working, .waiting: return .externalWork
        case .unknown: return .unknown
        }
    }

    enum DispatchBlock: LocalizedError, Equatable {
        case otherClient, externalWork, unknown

        var label: String {
            switch self {
            case .otherClient: "Open in another client"
            case .externalWork: "Active in another client"
            case .unknown: "Waiting for session status"
            }
        }

        var errorDescription: String? {
            switch self {
            case .otherClient: "This conversation is open in another client. Take it over here before sending or starting Voice Mode."
            case .externalWork: "This conversation is active in another client. Wait for it to finish before sending or starting Voice Mode here."
            case .unknown: "Could not verify whether this conversation is already running. Try again when its activity status is available."
            }
        }
    }
}

extension GatewayClient {
    func verifyDispatchAllowed(to sessionID: String?) async throws {
        guard let sessionID else { return }
        let activity = ConversationActivity(snapshot: try await readActiveTurns())
        if let block = activity.dispatchBlock(for: sessionID) { throw block }
    }
}
