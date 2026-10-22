import Foundation

struct LocalConfiguration: Decodable, Sendable {
    var codexWorkdir: String?
    var macMiniHostname: String?
    var macBookHostname: String?
    var codexGatewayPort: Int?
    var codexGatewayAuthToken: String?
    var googleMapsAPIKey: String?

    static func load(bundle: Bundle = .main) throws -> LocalConfiguration {
        guard let url = bundle.url(forResource: "RemoteCoderLocalConfig", withExtension: "json") else {
            return LocalConfiguration()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LocalConfiguration.self, from: data)
    }
}
