extension CodexAppServerV2 {
    enum DynamicToolCallOutputContentItem: Sendable, Equatable {
        case inputText(text: String)
        case inputImage(imageUrl: String)
    }
}


extension CodexAppServerV2.DynamicToolCallOutputContentItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "inputText":
            self = .inputText(text: try container.decode(String.self, forKey: .text))
        case "inputImage":
            self = .inputImage(imageUrl: try container.decode(String.self, forKey: .imageUrl))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown dynamic tool output item: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode("inputText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputImage(let imageUrl):
            try container.encode("inputImage", forKey: .type)
            try container.encode(imageUrl, forKey: .imageUrl)
        }
    }
}
