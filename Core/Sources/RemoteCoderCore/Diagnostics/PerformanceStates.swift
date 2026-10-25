import Foundation

struct UsageStateLabels: Equatable, Sendable {
    let surface: String?
    let turn: String?
    let connection: String?
    let voice: String?
    let energy: String?
}

extension UsageStateLabels {
    init(_ context: UsageContext, conservesEnergy: Bool) {
        let active = context.scene == .active
        surface = active ? context.surface?.rawValue : nil
        turn = active && context.turnRunningVisible == true ? "running" : nil
        connection = active ? context.route?.rawValue : nil
        voice = context.voiceCall ? "call" : nil
        energy = conservesEnergy ? "conserving" : nil
    }
}

enum HistoryActivity: String, Sendable {
    case opening, paging
}

struct HistoryOperations: Sendable {
    struct Operation: Equatable, Sendable {
        let id: UUID
        let activity: HistoryActivity
        let provider: AgentProvider
    }

    private var operations: [Operation] = []
    private var sceneActive = true

    var current: Operation? {
        operations.last { $0.activity == .opening } ?? operations.last
    }

    mutating func begin(_ activity: HistoryActivity, provider: AgentProvider) -> UUID {
        let id = UUID()
        if sceneActive { operations.append(Operation(id: id, activity: activity, provider: provider)) }
        return id
    }

    mutating func finish(_ id: UUID) {
        operations.removeAll { $0.id == id }
    }

    mutating func clear() {
        operations.removeAll()
    }

    mutating func sceneChanged(active: Bool) {
        sceneActive = active
        if !active { operations.removeAll() }
    }
}
