import Foundation

enum ThreadModelProvider: Sendable, Equatable {
    case native
    case external(id: String)

    init?(_ modelProvider: String?, threadID: String) {
        guard AgentProvider.provider(forThreadID: threadID) == .codex, let modelProvider else { return nil }
        self = modelProvider == "openai" ? .native : .external(id: modelProvider)
    }

    var externalID: String? {
        if case .external(let id) = self { id } else { nil }
    }

    var notice: String? {
        externalID.map { "Runs on \(Self.displayName(of: $0))" }
    }

    static func displayName(of id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }
}
