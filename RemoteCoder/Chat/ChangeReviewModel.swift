import Foundation
import Observation

@MainActor
@Observable
final class ChangeReviewModel {
    enum State {
        case loading
        case ready(ChangeReview)
        case unavailable(ChangeUnavailability)
        case noRecentEdits(isComplete: Bool)
        case anchorMissing(isComplete: Bool)
        case failed(String)
    }

    let conversation: String?
    let directory: String
    private(set) var view: ChangesView = .standard
    private(set) var state: State = .loading
    let summary: ChangeSummaryModel?
    private(set) var root: String?
    private(set) var startPoints = ChangesStartPoints.none
    private(set) var since: TurnChanges.Since?
    private(set) var isRefreshing = false
    private(set) var collapsedFiles: [ReviewedFile.ID: Bool] = [:]
    private(set) var notes: [ReviewNote.Anchor: ReviewNoteDraft] = [:]
    var focusedNote: ReviewNote.Anchor?
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")

    init(conversation: String?, directory: String, client: GatewayClient, summary: ChangeSummaryModel?) {
        self.conversation = conversation
        self.directory = directory
        self.client = client
        self.summary = summary
    }

    func reviews(conversation: String?, directory: String?, through client: GatewayClient) -> Bool {
        self.conversation == conversation && self.directory == directory && self.client === client
    }

    var selectedView: ChangesView {
        get { view }
        set { select(newValue) }
    }

    var offersConversationViews: Bool {
        conversation != nil && summary?.offersViews == true
    }

    var selectedRoot: String? {
        get { root }
        set { select(root: newValue) }
    }

    func select(_ view: ChangesView) {
        if let summary, view != summary.view { summary.select(view) }
        guard view != self.view else { return }
        self.view = view
        state = .loading
        load()
    }

    func countFromNow() {
        guard let conversation else { return }
        loading?.cancel()
        revision += 1
        let revision = revision
        isRefreshing = true
        loading = Task { [weak self, client] in
            let turnID: String?
            do {
                turnID = try await client.readNewestTurnID(threadID: conversation)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.revision == revision else { return }
                self.logger.notice("Reading the newest turn failed: \(error.localizedDescription)")
                self.isRefreshing = false
                return
            }
            guard let self, self.revision == revision, !Task.isCancelled else { return }
            self.isRefreshing = false
            guard let turnID else { return }
            self.select(.since(ChangesAnchor(turnID: turnID, boundary: .end)))
        }
    }

    func title(of view: ChangesView) -> String {
        if case .since(let anchor) = view {
            if let since, since.anchor == anchor, let label = view.label(since: since) { return label }
            if let content = summary?.content, content.view == view, let label = content.label { return label }
        }
        return view.label(since: nil) ?? ChangeSource.branch.title
    }

    func select(root: String?) {
        guard let root, root != self.root else { return }
        self.root = root
        state = .loading
        load()
    }

    func refresh() {
        summary?.refresh()
        startPoints = summary?.startPoints() ?? .none
        load()
    }

    func reopen() {
        let primary = summary?.summary?.primary
        let initial: ChangesView = switch offersConversationViews ? summary?.view : nil {
        case nil, .git(.branch)?: .git(primary?.source ?? .branch)
        case let stored?: stored
        }
        let root = primary?.root ?? summary?.summary?.workedIn.first?.root
        if view != initial || self.root != root {
            view = initial
            self.root = root
            state = .loading
        }
        refresh()
    }

    private func load() {
        loading?.cancel()
        revision += 1
        let revision = revision
        let view = view
        let chosen = root ?? summary?.summary.flatMap { $0.primary?.root ?? $0.workedIn.first?.root }
        let resolvesRoot = chosen == nil && summary?.summary == nil
        isRefreshing = true
        loading = Task { [weak self, client, conversation, directory] in
            let result: State
            var resolved = chosen
            do {
                switch view {
                case .lastTurn, .since:
                    guard let conversation else {
                        result = .noRecentEdits(isComplete: true)
                        break
                    }
                    switch try await client.readTurnChanges(threadID: conversation, since: view.anchor) {
                    case .ready(let changes): result = .ready(await ChangeReviewPreparation.prepare(changes, revision: revision))
                    case .noRecentEdits(let complete): result = .noRecentEdits(isComplete: complete)
                    case .anchorMissing(let complete): result = .anchorMissing(isComplete: complete)
                    }
                case .git(let source):
                    if resolvesRoot, let conversation {
                        resolved = try await Self.primaryRoot(client: client, conversation: conversation, directory: directory)
                    }
                    switch try await client.readChanges(directory: resolved ?? directory, source: source) {
                    case .ready(let snapshot): result = .ready(await ChangeReviewPreparation.prepare(snapshot, revision: revision))
                    case .unavailable(let reason): result = .unavailable(reason)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard let self, self.revision == revision, !Task.isCancelled else { return }
            if case .git = view, self.root == nil, let resolved { self.root = resolved }
            if case .failed(let message) = result { self.logger.notice("Reading changes failed: \(message)") }
            if case .ready(let review) = result, case .conversation(.since(let since), _, _) = review.scope { self.since = since }
            self.state = result
            self.isRefreshing = false
        }
    }

    @concurrent private static func primaryRoot(client: GatewayClient, conversation: String, directory: String) async throws -> String? {
        let summary = PreparedChangeSummary(try await client.readChangeSummary(threadID: conversation, directory: directory, source: nil))
        return summary.primary?.root ?? summary.workedIn.first?.root
    }

    func stop() {
        loading?.cancel()
        loading = nil
        isRefreshing = false
    }

    func isCollapsed(_ file: ReviewedFile) -> Bool {
        collapsedFiles[file.id] ?? (file.rows.count > Self.collapsedLineCount)
    }

    func toggleCollapsed(_ file: ReviewedFile) {
        collapsedFiles[file.id] = !isCollapsed(file)
    }

    func setAllCollapsed(_ collapsed: Bool, in review: ChangeReview) {
        for file in review.files { collapsedFiles[file.id] = collapsed }
    }

    func noteCount(in file: ReviewedFile) -> Int {
        notes.keys.count(where: { $0.comparison == file.comparison && $0.root == file.root && $0.path == file.path })
    }

    func comment(on anchor: ReviewNote.Anchor) {
        if notes[anchor] == nil { notes[anchor] = ReviewNoteDraft(anchor: anchor) }
        focusedNote = anchor
    }

    func delete(_ anchor: ReviewNote.Anchor) {
        notes[anchor] = nil
        if focusedNote == anchor { focusedNote = nil }
    }

    var writtenNoteCount: Int {
        notes.values.count(where: \.isWritten)
    }

    func notes(outside review: ChangeReview?) -> [ReviewNoteDraft] {
        notes.values.filter { draft in review?.contains(draft.anchor) != true }
            .sorted { ($0.anchor.root, $0.anchor.path, $0.anchor.line) < ($1.anchor.root, $1.anchor.path, $1.anchor.line) }
    }

    func commentsPrompt() -> String? {
        let order: [String: Int]
        if case .ready(let review) = state {
            order = Dictionary(review.files.enumerated().map { (Self.location($1.root, $1.path), $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            order = [:]
        }
        let sorted = notes.values.map { ReviewNote(anchor: $0.anchor, text: $0.text) }.sorted {
            let left = (Self.rank($0.anchor.comparison), Self.turnStart($0.anchor.comparison),
                        order[Self.location($0.anchor.root, $0.anchor.path)] ?? .max, $0.anchor.root, $0.anchor.path, $0.anchor.line)
            let right = (Self.rank($1.anchor.comparison), Self.turnStart($1.anchor.comparison),
                         order[Self.location($1.anchor.root, $1.anchor.path)] ?? .max, $1.anchor.root, $1.anchor.path, $1.anchor.line)
            return left < right
        }
        return ReviewNote.prompt(sorted, scope: scope(of:))
    }

    func title(of comparison: ReviewComparison) -> String {
        switch comparison {
        case .git(let source): source.title
        case .turn(_, let startedAt): "Turn at \(ChangesView.formattedTime(startedAt))"
        case .since(_, let at): at.map { "Since \(ChangesView.formattedTime($0))" } ?? "Since Start Point"
        }
    }

    func clearNotes() {
        notes = [:]
        focusedNote = nil
    }

    private func scope(of anchor: ReviewNote.Anchor) -> String {
        let changes = switch anchor.comparison {
        case .git(.uncommitted): "the uncommitted changes"
        case .git(.staged): "the staged changes"
        case .git(.unstaged): "the unstaged changes"
        case .git(.branch):
            if case .ready(let review) = state, case .git(.branch, let root, _, let base?) = review.scope, root == anchor.root {
                "this branch's changes against \(base)"
            } else {
                "this branch's changes"
            }
        case .turn(_, let startedAt): "the edits of the turn that started at \(ChangesView.formattedTime(startedAt))"
        case .since(_, let at): at.map { "the edits made since \(ChangesView.formattedTime($0))" } ?? "the edits made since the start point"
        }
        return "\(changes) in \(anchor.root)"
    }

    private static func rank(_ comparison: ReviewComparison) -> Int {
        switch comparison {
        case .git(let source): ChangeSource.allCases.firstIndex(of: source) ?? 0
        case .turn: ChangeSource.allCases.count
        case .since: ChangeSource.allCases.count + 1
        }
    }

    private static func turnStart(_ comparison: ReviewComparison) -> Date {
        switch comparison {
        case .turn(_, let startedAt): startedAt
        case .since(_, let at): at ?? .distantPast
        case .git: .distantPast
        }
    }

    private static func location(_ root: String, _ path: String) -> String {
        (root as NSString).appendingPathComponent(path)
    }

    private static let collapsedLineCount = 400
}

@MainActor
@Observable
final class ReviewNoteDraft: Identifiable {
    let id = UUID()
    let anchor: ReviewNote.Anchor
    var text = ""

    init(anchor: ReviewNote.Anchor) {
        self.anchor = anchor
    }

    var isWritten: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#if DEBUG
extension ChangeReviewModel {
    func showPreview(_ state: State, view: ChangesView = .standard, root: String? = nil,
                     notes: [ReviewNote] = []) {
        self.state = state
        self.view = view
        self.root = root
        isRefreshing = false
        self.notes = Dictionary(uniqueKeysWithValues: notes.map { note in
            let draft = ReviewNoteDraft(anchor: note.anchor)
            draft.text = note.text
            return (note.anchor, draft)
        })
    }
}
#endif
