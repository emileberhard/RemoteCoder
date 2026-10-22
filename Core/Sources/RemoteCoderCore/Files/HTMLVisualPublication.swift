import Foundation

struct HTMLVisualPublication: Sendable, Equatable {
    let reference: HTMLVisualReference
    let title: String
}

extension HTMLVisualPublication: Codable {
    private enum CodingKeys: String, CodingKey { case digest, title }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let digest = try container.decode(String.self, forKey: .digest)
        guard let url = URL(string: "rc-visual:" + digest), let reference = HTMLVisualReference(url: url) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: container, debugDescription: "Invalid visual digest")
        }
        let title = try container.decode(String.self, forKey: .title)
        self.init(reference: reference, title: title)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reference.digest, forKey: .digest)
        try container.encode(title, forKey: .title)
    }
}
