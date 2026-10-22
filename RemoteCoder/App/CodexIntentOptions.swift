import AppIntents
import Foundation

@AppEntity(schema: .phone.phonePerson)
struct CodexModelEntity {
    static let appDefaultID = "app-default"
    static let defaultQuery = CodexModelQuery()

    let id: String
    let name: String
    let subtitle: String?

    var person: IntentPerson {
        IntentPerson(identifier: .applicationDefined(id), name: .displayName(name), handle: IntentPerson.Handle(applicationDefined: id))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: subtitle.map(LocalizedStringResource.init(stringLiteral:))
        )
    }

    init(option: ModelOption) {
        id = option.id
        name = option.displayName
        subtitle = nil
    }

    @MainActor
    static func appDefault(in workspace: ChatWorkspaceModel) -> CodexModelEntity {
        CodexModelEntity(id: appDefaultID, name: "App Default", subtitle: workspace.newChatDefaultModel().model?.displayName)
    }

    @MainActor
    static func resolving(_ id: ID, in workspace: ChatWorkspaceModel) -> CodexModelEntity {
        if id == appDefaultID { return appDefault(in: workspace) }
        return workspace.configuredModel(id: id).model.map(CodexModelEntity.init(option:)) ?? CodexModelEntity(id: id, name: id, subtitle: nil)
    }

    private init(id: String, name: String, subtitle: String?) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
    }
}

struct CodexModelQuery: EntityStringQuery, EnumerableEntityQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    @Dependency private var workspace: ChatWorkspaceModel

    func entities(for identifiers: [CodexModelEntity.ID]) async throws -> [CodexModelEntity] {
        let workspace = workspace
        return try await workspace.readNewChatModelCatalog {
            identifiers.map { CodexModelEntity.resolving($0, in: workspace) }
        }
    }

    func entities(matching string: String) async throws -> [CodexModelEntity] {
        try await allEntities().filter { $0.name.localizedStandardContains(string) || $0.id.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [CodexModelEntity] {
        try await allEntities()
    }

    func allEntities() async throws -> [CodexModelEntity] {
        let workspace = workspace
        return try await Self.entities(in: workspace)
    }

    func defaultResult() async -> CodexModelEntity? {
        let workspace = workspace
        return try? await workspace.readNewChatModelCatalog { CodexModelEntity.appDefault(in: workspace) }
    }

    @MainActor
    static func entities(in workspace: ChatWorkspaceModel) async throws -> [CodexModelEntity] {
        try await workspace.readNewChatModelCatalog {
            [CodexModelEntity.appDefault(in: workspace)]
                + workspace.newChatModelOptions(preferredHostID: workspace.selectedHostID).map(CodexModelEntity.init(option:))
        }
    }
}

@UnionValue
enum VoiceCallDestination {
    case model(CodexModelEntity)
    case group([CodexModelEntity])

    var model: CodexModelEntity {
        get throws {
            switch self {
            case .model(let model):
                return model
            case .group(let models):
                guard models.count == 1, let model = models.first else { throw VoiceModeConfigurationError.groupCall }
                return model
            }
        }
    }
}

@AppEnum(schema: .phone.audioVisualMode)
enum VoiceCallMode: String, Sendable {
    case audio
    case video

    static let caseDisplayRepresentations: [VoiceCallMode: DisplayRepresentation] = [
        .audio: "Audio",
        .video: "Video",
    ]
}

enum CodexIntentReasoning: String, AppEnum, Sendable {
    case appDefault = "app-default"
    case automatic
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reasoning"
    static let caseDisplayRepresentations: [CodexIntentReasoning: DisplayRepresentation] = [
        .appDefault: "App Default",
        .automatic: "Automatic",
        .low: "Low",
        .medium: "Medium",
        .high: "High",
        .xhigh: "X-High",
        .max: "Max",
        .ultra: "Ultra",
    ]

    var selectionID: String? {
        switch self {
        case .appDefault: nil
        case .automatic: "automatic"
        case .low, .medium, .high, .xhigh, .max, .ultra: "effort-\(rawValue)"
        }
    }
}

enum CodexIntentFastMode: String, AppEnum, Sendable {
    case appDefault = "app-default"
    case on
    case off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fast Mode"
    static let caseDisplayRepresentations: [CodexIntentFastMode: DisplayRepresentation] = [
        .appDefault: "App Default",
        .on: "On",
        .off: "Off",
    ]

    var isEnabled: Bool {
        switch self {
        case .appDefault:
            return NewChatDefaults.fastModeEnabled()
        case .on:
            return true
        case .off:
            return false
        }
    }
}

@MainActor
enum CodexIntentModelCatalog {
    static func resolve(_ entity: CodexModelEntity?, in workspace: ChatWorkspaceModel) async throws -> ModelOption {
        try Task.checkCancellation()
        guard let entity, entity.id != CodexModelEntity.appDefaultID else {
            if case .listNotLoaded = workspace.newChatDefaultModel() {
                return try await workspace.readNewChatModelCatalog {
                    try workspace.newChatDefaultModel().requireModel(ifNotOffered: .noModelShown)
                }
            }
            return try workspace.newChatDefaultModel().requireModel(ifNotOffered: .noModelShown)
        }
        if case .listNotLoaded = workspace.configuredModel(id: entity.id) {
            return try await workspace.readNewChatModelCatalog {
                try workspace.configuredModel(id: entity.id).requireModel(ifNotOffered: .modelNotOffered(entity.name))
            }
        }
        return try workspace.configuredModel(id: entity.id).requireModel(ifNotOffered: .modelNotOffered(entity.name))
    }
}
