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

    var modelProvider: CodexAppServerV2.ModelProvider? {
        externalID.map { .init(id: $0, name: Self.displayName(of: $0)) }
    }

    var notice: String? {
        modelProvider.map { "Runs on \($0.name)" }
    }

    static func displayName(of id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }
}
