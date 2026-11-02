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

struct CheckoutDiscovery: Decodable, Sendable {
    struct Checkout: Decodable, Sendable {
        enum Evidence: String, Decodable, Sendable {
            case edited, command, workingFolder
        }

        let root: String
        let evidence: Set<Evidence>
    }

    let workedIn: [Checkout]
    let inFolder: [String]
    let complete: Bool

    var defaultRoot: String? {
        (workedIn.first { $0.evidence.contains(.edited) } ?? workedIn.first)?.root
    }
}

enum TurnChangesRead: Decodable, Sendable {
    case ready(TurnChanges)
    case noRecentEdits(complete: Bool)

    private enum CodingKeys: String, CodingKey {
        case status, complete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "ready": self = .ready(try TurnChanges(from: decoder))
        case "noRecentEdits": self = .noRecentEdits(complete: try container.decode(Bool.self, forKey: .complete))
        case let status:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "Unknown turn changes status \(status)")
        }
    }
}

struct TurnChanges: Decodable, Sendable {
    struct Turn: Decodable, Sendable {
        let id: String
        let startedAtMs: Int64
        let running: Bool
        let latest: Bool

        var startedAt: Date {
            Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        }
    }

    struct File: Sendable {
        let root: String
        let change: ChangeSnapshot.File
    }

    let turn: Turn
    let files: [File]
    let unlistedFiles: Int
    let commands: Int
    let omittedAgents: Int
    let complete: Bool
    let capturedAtMs: Int64
}

extension TurnChanges.File: Decodable {
    private enum CodingKeys: String, CodingKey {
        case root
    }

    init(from decoder: any Decoder) throws {
        root = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .root)
        change = try ChangeSnapshot.File(from: decoder)
    }
}
