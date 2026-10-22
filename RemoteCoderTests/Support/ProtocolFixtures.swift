import Foundation
import Testing

enum ProtocolFixtures {
    private final class BundleAnchor: NSObject {}

    static func data(named name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle(for: BundleAnchor.self).url(forResource: name, withExtension: "json")))
    }
}
