import Foundation

struct UsageStateLabels: Equatable, Sendable {
    let surface: String?
    let turn: String?
    let route: String?
    let voice: String?
    let energy: String?
    var composing: String? = nil
}

extension UsageStateLabels {
    init(_ context: UsageContext, conservesEnergy: Bool) {
        let foreground = context.scene != .background
        surface = foreground ? context.surface?.rawValue : nil
        turn = foreground && context.turnRunningVisible == true ? "running" : nil
        route = foreground ? context.route?.rawValue : nil
        voice = context.voiceCall ? "call" : context.recording == true ? "recording" : nil
        energy = conservesEnergy ? "conserving" : nil
        composing = foreground && context.composing == true ? "editing" : nil
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

    enum Report: Equatable, Sendable {
        case transition(Operation?)
        case operationChanged(UUID)
    }

    private var operations: [Operation] = []
    private var inBackground: Bool?
    private var reported: Operation?

    var current: Operation? {
        operations.last { $0.activity == .opening } ?? operations.last
    }

    mutating func begin(_ activity: HistoryActivity, provider: AgentProvider) -> UUID {
        let id = UUID()
        operations.append(Operation(id: id, activity: activity, provider: provider))
        return id
    }

    mutating func finish(_ id: UUID) {
        operations.removeAll { $0.id == id }
    }

    mutating func sceneChanged(background: Bool) {
        if background, inBackground == false { operations.removeAll() }
        inBackground = background
    }

    mutating func report() -> Report? {
        let current = current
        defer { reported = current }
        guard current != reported else { return nil }
        if let current, let reported, current.activity == reported.activity, current.provider == reported.provider {
            return .operationChanged(current.id)
        }
        return .transition(current)
    }
}
