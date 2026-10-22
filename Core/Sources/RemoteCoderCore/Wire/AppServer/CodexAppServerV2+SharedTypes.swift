// Shared wire-level primitives used across app-server v2 payloads.

extension CodexAppServerV2 {
    enum ReasoningSummary: String, Codable, Sendable, Hashable {
        case detailed
    }

    struct ReasoningEffort: RawRepresentable, Codable, Sendable, Hashable {
        let rawValue: String

        init?(rawValue: String) {
            guard rawValue.isEmpty == false else { return nil }
            self.rawValue = rawValue
        }

        private init(validatedRawValue: String) {
            rawValue = validatedRawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Reasoning effort must not be empty"
                )
            }
            self = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        static let none = Self(validatedRawValue: "none")
        static let minimal = Self(validatedRawValue: "minimal")
        static let low = Self(validatedRawValue: "low")
        static let medium = Self(validatedRawValue: "medium")
        static let high = Self(validatedRawValue: "high")
        static let xhigh = Self(validatedRawValue: "xhigh")
        static let max = Self(validatedRawValue: "max")
        static let ultra = Self(validatedRawValue: "ultra")
    }

    enum ServiceTier: String, Codable, Sendable, Hashable {
        case fast
        case flex

        init?(wireValue: String) {
            self.init(rawValue: wireValue == "priority" ? "fast" : wireValue)
        }

        static func fastModeSelection(for wireValue: String?) -> Bool? {
            guard let wireValue else { return false }
            if wireValue == "default" { return false }
            return Self(wireValue: wireValue) == .fast ? true : nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let tier = Self(wireValue: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown service tier: \(value)")
            }
            self = tier
        }
    }

    enum ServiceTierOverride: Sendable, Hashable {
        case clear
        case set(ServiceTier)
    }

    enum InputModality: String, Codable, Sendable, Hashable {
        case text
        case image
        case audio
    }
}

extension CodexAppServerV2.ServiceTierOverride: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .clear
            return
        }
        self = .set(try container.decode(CodexAppServerV2.ServiceTier.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .clear:
            try container.encodeNil()
        case .set(let tier):
            try container.encode(tier)
        }
    }
}
