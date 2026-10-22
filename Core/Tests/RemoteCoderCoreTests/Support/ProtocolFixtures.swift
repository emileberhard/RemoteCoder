import Foundation

enum ProtocolFixtures {
    struct MissingFixture: Error { let name: String }

    static func data(at path: String) throws -> Data {
        try Data(contentsOf: root.appending(path: path))
    }

    static func data(named name: String) throws -> Data {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
              let url = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "\(name).json" }) else {
            throw MissingFixture(name: name)
        }
        return try Data(contentsOf: url)
    }

    private static var root: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "protocol-fixtures")
    }
}
