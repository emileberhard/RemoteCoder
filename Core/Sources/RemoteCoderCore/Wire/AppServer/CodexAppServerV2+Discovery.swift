extension CodexAppServerV2 {
    struct ModelListParams: Encodable, Sendable, Hashable {
        let cursor: String?
        let includeHidden = true
    }

    struct Model: Sendable, Hashable {
        let model: String
        let displayName: String
        let description: String
        let supportedReasoningEfforts: [ReasoningEffortOption]
        let inputModalities: [InputModality]
        let additionalSpeedTiers: [String]
        let serviceTiers: [ModelServiceTier]
        let availableAccessPrograms: ModelAccessPrograms?
        let hidden: Bool
        let isDefault: Bool
    }

    struct ModelServiceTier: Codable, Sendable, Hashable {
        let id: String
    }

    struct ModelAccessPrograms: Codable, Sendable, Hashable {
        let cyber: [String]
    }

    struct ReasoningEffortOption: Codable, Sendable, Hashable {
        let reasoningEffort: ReasoningEffort
    }

    struct ModelListResponse: Codable, Sendable, Hashable {
        let data: [Model]
        let nextCursor: String?
    }

    struct FsReadDirectoryParams: Encodable, Sendable, Hashable {
        let path: String
    }

    struct FsReadDirectoryResponse: Codable, Sendable, Hashable {
        let entries: [FsReadDirectoryEntry]
    }

    struct FsReadDirectoryEntry: Codable, Sendable, Hashable {
        let fileName: String
        let isDirectory: Bool
    }

    struct CommandExecParams: Encodable, Sendable, Hashable {
        let command: [String]
        let cwd: String?
    }

    struct CommandExecResponse: Codable, Sendable, Hashable {
        let exitCode: Int
        let stdout: String
        let stderr: String
    }
}


extension CodexAppServerV2.Model: Codable {
    private enum CodingKeys: String, CodingKey {
        case model
        case displayName
        case description
        case supportedReasoningEfforts
        case inputModalities
        case additionalSpeedTiers
        case serviceTiers
        case availableAccessPrograms
        case hidden
        case isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.description = try container.decode(String.self, forKey: .description)
        self.supportedReasoningEfforts = try container.decode([CodexAppServerV2.ReasoningEffortOption].self, forKey: .supportedReasoningEfforts)
        self.inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities)?
            .compactMap(CodexAppServerV2.InputModality.init(rawValue:)) ?? [.text, .image]
        self.additionalSpeedTiers = try container.decodeIfPresent([String].self, forKey: .additionalSpeedTiers) ?? []
        self.serviceTiers = try container.decodeIfPresent([CodexAppServerV2.ModelServiceTier].self, forKey: .serviceTiers) ?? []
        self.availableAccessPrograms = try container.decodeIfPresent(CodexAppServerV2.ModelAccessPrograms.self, forKey: .availableAccessPrograms)
        self.hidden = try container.decode(Bool.self, forKey: .hidden)
        self.isDefault = try container.decode(Bool.self, forKey: .isDefault)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encode(inputModalities, forKey: .inputModalities)
        try container.encode(additionalSpeedTiers, forKey: .additionalSpeedTiers)
        try container.encode(serviceTiers, forKey: .serviceTiers)
        try container.encodeIfPresent(availableAccessPrograms, forKey: .availableAccessPrograms)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(isDefault, forKey: .isDefault)
    }
}
