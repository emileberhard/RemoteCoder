import Foundation

enum ChangeSource: String, Codable, CaseIterable, Hashable, Sendable {
    case uncommitted, staged, unstaged, branch
}

enum ChangeRead: Decodable, Sendable {
    case ready(ChangeSnapshot)
    case unavailable(ChangeUnavailability)

    private enum CodingKeys: String, CodingKey {
        case status, snapshot, reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "ready": self = .ready(try container.decode(ChangeSnapshot.self, forKey: .snapshot))
        case "unavailable": self = .unavailable(try container.decode(ChangeUnavailability.self, forKey: .reason))
        case let status:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "Unknown change read status \(status)")
        }
    }
}

enum ChangeUnavailability: String, Decodable, Sendable {
    case missingDirectory, notRepository, noBaseBranch, noMergeBase
}

struct ChangeSnapshot: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let patch: String
        let additions: Int
        let deletions: Int
        let omitted: Omission?
        let replacedInvalidUtf8: Bool
    }

    struct Omission: Decodable, Equatable, Sendable {
        enum Reason: String, Decodable, Sendable {
            case fileTooLarge, responseBudget
        }

        let reason: Reason
        let patchBytes: Int
    }

    let source: ChangeSource
    let root: String
    let branch: String?
    let base: String?
    let capturedAtMs: Int64
    let files: [File]
    let unlistedFiles: Int
    let complete: Bool
}
