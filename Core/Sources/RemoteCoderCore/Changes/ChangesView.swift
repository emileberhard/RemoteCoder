import Foundation

struct ChangesAnchor: Hashable, Sendable {
    enum Boundary: String, Codable, Sendable {
        case start, end
    }

    let turnID: String
    let boundary: Boundary
}

enum ChangesView: Hashable, Sendable {
    case git(ChangeSource)
    case lastTurn
    case since(ChangesAnchor)

    static let standard = ChangesView.git(.branch)

    var anchor: ChangesAnchor? {
        if case .since(let anchor) = self { anchor } else { nil }
    }

    var source: ChangeSource? {
        if case .git(let source) = self { source } else { nil }
    }
}

extension ChangesView: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, source, turnId, boundary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "lastTurn": self = .lastTurn
        case "git": self = .git(try container.decode(ChangeSource.self, forKey: .source))
        case "since":
            self = .since(ChangesAnchor(turnID: try container.decode(String.self, forKey: .turnId),
                                        boundary: try container.decode(ChangesAnchor.Boundary.self, forKey: .boundary)))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown changes view \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lastTurn:
            try container.encode("lastTurn", forKey: .kind)
        case .git(let source):
            try container.encode("git", forKey: .kind)
            try container.encode(source, forKey: .source)
        case .since(let anchor):
            try container.encode("since", forKey: .kind)
            try container.encode(anchor.turnID, forKey: .turnId)
            try container.encode(anchor.boundary, forKey: .boundary)
        }
    }
}

struct ChangesPillContent: Equatable, Sendable {
    enum Count: Equatable, Sendable {
        case known(ChangeTotals)
        case unknown
        case startMissing
    }

    let view: ChangesView
    let label: String?
    let count: Count

    init(view: ChangesView, since: TurnChanges.Since? = nil, count: Count, now: Date = .now) {
        self.view = view
        label = view.label(since: since, now: now)
        self.count = count
    }

    var isVisible: Bool {
        guard view == .standard else { return true }
        if case .known(let totals) = count { return totals.files > 0 }
        return false
    }
}

struct ChangeSummaryRead: Equatable, Sendable {
    let directory: String
    let content: ChangesPillContent
    let summary: PreparedChangeSummary?
}

extension ChangesView {
    func label(since: TurnChanges.Since?, now: Date = .now) -> String? {
        switch self {
        case .git(.branch): nil
        case .git(let source): source.title
        case .lastTurn: "Last Turn"
        case .since(let anchor):
            if let at = since?.at {
                "Since \(Self.formattedTime(at, now: now))"
            } else if since != nil, anchor.boundary == .end {
                "Since Now"
            } else {
                "Since"
            }
        }
    }

    static func formattedTime(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
                                                         : date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension ChangeSource {
    var title: String {
        switch self {
        case .uncommitted: "Uncommitted"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .branch: "Branch"
        }
    }
}

struct ChangesStartPoints: Equatable, Sendable {
    struct Prompt: Equatable, Identifiable, Sendable {
        let anchor: ChangesAnchor
        let preview: String
        let date: Date

        var id: String { anchor.turnID }
    }

    static let limit = 6
    private static let previewCharacters = 80

    let prompts: [Prompt]

    static let none = ChangesStartPoints(prompts: [])

    init(prompts: [Prompt]) {
        self.prompts = prompts
    }

    init(messages: [ChatMessage]) {
        var prompts: [Prompt] = []
        var seen: Set<String> = []
        for message in messages.reversed() where message.role == .user && !message.wasSteered {
            guard prompts.count < Self.limit else { break }
            guard let turnID = message.canonicalTurnID, seen.insert(turnID).inserted else { continue }
            prompts.append(Prompt(anchor: ChangesAnchor(turnID: turnID, boundary: .start),
                                  preview: Self.preview(of: message.text), date: message.date))
        }
        self.init(prompts: prompts)
    }

    private static func preview(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > previewCharacters ? String(line.prefix(previewCharacters)) + "…" : line
    }
}
