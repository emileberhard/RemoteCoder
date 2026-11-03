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

enum TurnChangesRead: Decodable, Sendable {
    case ready(TurnChanges)
    case noRecentEdits(complete: Bool)
    case anchorMissing(complete: Bool)

    private enum CodingKeys: String, CodingKey {
        case status, complete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "ready": self = .ready(try TurnChanges(from: decoder))
        case "noRecentEdits": self = .noRecentEdits(complete: try container.decode(Bool.self, forKey: .complete))
        case "anchorMissing": self = .anchorMissing(complete: try container.decode(Bool.self, forKey: .complete))
        case let status:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "Unknown turn changes status \(status)")
        }
    }
}

struct TurnChanges: Decodable, Sendable {
    struct Turn: Decodable, Hashable, Sendable {
        let id: String
        let startedAtMs: Int64
        let running: Bool
        let latest: Bool

        var startedAt: Date {
            Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        }
    }

    struct Since: Hashable, Sendable {
        let anchor: ChangesAnchor
        let atMs: Int64?
        let turns: Int

        var at: Date? {
            atMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
        }
    }

    enum Window: Hashable, Sendable {
        case turn(Turn)
        case since(Since)
    }

    struct File: Sendable {
        let root: String
        let change: ChangeSnapshot.File
    }

    let window: Window
    let files: [File]
    let unlistedFiles: Int
    let commands: Int
    let omittedAgents: Int
    let complete: Bool
    let capturedAtMs: Int64

    private enum CodingKeys: String, CodingKey {
        case turn, since, turns, files, unlistedFiles, commands, omittedAgents, complete, capturedAtMs
    }

    private struct Start: Decodable {
        let turnId: String
        let boundary: ChangesAnchor.Boundary
        let atMs: Int64?
    }

    init(window: Window, files: [File], unlistedFiles: Int, commands: Int, omittedAgents: Int, complete: Bool,
         capturedAtMs: Int64) {
        self.window = window
        self.files = files
        self.unlistedFiles = unlistedFiles
        self.commands = commands
        self.omittedAgents = omittedAgents
        self.complete = complete
        self.capturedAtMs = capturedAtMs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let start = try container.decodeIfPresent(Start.self, forKey: .since) {
            window = .since(Since(anchor: ChangesAnchor(turnID: start.turnId, boundary: start.boundary), atMs: start.atMs,
                                  turns: try container.decode(Int.self, forKey: .turns)))
        } else {
            window = .turn(try container.decode(Turn.self, forKey: .turn))
        }
        files = try container.decode([File].self, forKey: .files)
        unlistedFiles = try container.decode(Int.self, forKey: .unlistedFiles)
        commands = try container.decode(Int.self, forKey: .commands)
        omittedAgents = try container.decode(Int.self, forKey: .omittedAgents)
        complete = try container.decode(Bool.self, forKey: .complete)
        capturedAtMs = try container.decode(Int64.self, forKey: .capturedAtMs)
    }

    var totals: ChangeTotals {
        ChangeTotals(counted: files.lazy.map { UnifiedDiff.header(of: $0.change).countedLines },
                     unlistedFiles: unlistedFiles, isComplete: complete)
    }
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
