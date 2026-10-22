import Foundation

struct BuildIdentity: Equatable, Sendable, Decodable {
    let version: String
    let commit: String?
    let modified: Bool?
    private let buildNumber: String?

    static let currentApp = BuildIdentity(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        commit = Self.fullCommit(info["RemoteCoderSourceCommit"] as? String)
        modified = switch info["RemoteCoderSourceModified"] as? String {
        case "true": true
        case "false": false
        default: nil
        }
        let marketingVersion = info["CFBundleShortVersionString"] as? String
        if let marketingVersion, marketingVersion != "0.0.0", Self.isReleaseVersion(marketingVersion),
           modified == false, commit != nil {
            version = marketingVersion
        } else {
            version = "dev"
        }
        buildNumber = Self.recorded(info["CFBundleVersion"] as? String)
    }

    private enum CodingKeys: String, CodingKey {
        case version, commit, modified
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        commit = Self.fullCommit(try values.decodeIfPresent(String.self, forKey: .commit))
        modified = try values.decodeIfPresent(Bool.self, forKey: .modified)
        buildNumber = nil
        guard version == "dev" || (Self.isReleaseVersion(version) && commit != nil && modified == false) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Invalid gateway build identity")
        }
    }

    var display: String {
        if version != "dev" {
            let build = buildNumber.map { " (\($0))" } ?? ""
            return "\(version)\(build) · \(commit.map { String($0.prefix(8)) } ?? "")"
        }
        guard let commit else { return "Dev" }
        return "Dev · \(commit.prefix(8))\(modified == true ? " (modified)" : "")"
    }

    private static func recorded(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unrecorded" else { return nil }
        return value
    }

    private static func fullCommit(_ value: String?) -> String? {
        guard let value, value.utf8.count == 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    private static func isReleaseVersion(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.enumerated().allSatisfy { index, part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                && (part.count == 1 || part.first != "0")
                && Int(part).map { index == 0 || $0 <= 999 } == true
        }
    }
}
