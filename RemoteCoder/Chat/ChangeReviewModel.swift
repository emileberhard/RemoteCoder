import Foundation
import Observation

@MainActor
@Observable
final class ChangeReviewModel {
    enum Mode: Hashable {
        case lastTurn
        case git(ChangeSource)

        static let all: [Mode] = [.lastTurn] + ChangeSource.allCases.map(Mode.git)
    }

    nonisolated static let defaultSource = ChangeSource.uncommitted

    enum State {
        case loading
        case ready(ChangeReview)
        case unavailable(ChangeUnavailability)
        case noRecentEdits(isComplete: Bool)
        case failed(String)
    }

    enum Checkouts {
        case unknown
        case failed
        case found(CheckoutDiscovery)
    }

    let conversation: String?
    let directory: String
    private(set) var mode: Mode = .git(defaultSource)
    private(set) var state: State = .loading
    private(set) var checkouts: Checkouts = .unknown
    private(set) var root: String?
    private(set) var isRefreshing = false
    private(set) var collapsedFiles: [ReviewedFile.ID: Bool] = [:]
    private(set) var notes: [ReviewNote.Anchor: ReviewNoteDraft] = [:]
    var focusedNote: ReviewNote.Anchor?
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private var chosenRoot: String?
    @ObservationIgnored private var discoversCheckouts = true
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")

    init(conversation: String?, directory: String, client: GatewayClient) {
        self.conversation = conversation
        self.directory = directory
        self.client = client
    }

    func reviews(conversation: String?, directory: String?, through client: GatewayClient) -> Bool {
        self.conversation == conversation && self.directory == directory && self.client === client
    }

    var selectedMode: Mode {
        get { mode }
        set { select(newValue) }
    }

    var selectedRoot: String? {
        get { root }
        set { select(root: newValue) }
    }

    func select(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        state = .loading
        load()
    }

    func select(root: String?) {
        guard let root, root != chosenRoot else { return }
        chosenRoot = root
        if root != self.root {
            self.root = root
            state = .loading
        }
        load()
    }

    func refresh() {
        discoversCheckouts = true
        load()
    }

    func reopen() {
        let initial = Mode.git(Self.defaultSource)
        if mode != initial || chosenRoot != nil {
            mode = initial
            chosenRoot = nil
            root = nil
            state = .loading
        }
        refresh()
    }

    private func load() {
        loading?.cancel()
        revision += 1
        let revision = revision
        let mode = mode
        let chosen = chosenRoot
        let known = checkouts
        let discovering = discoversCheckouts
        isRefreshing = true
        loading = Task { [weak self, client, conversation, directory] in
            let result: State
            var discovered: Checkouts?
            var reviewed: String?
            do {
                switch mode {
                case .lastTurn:
                    guard let conversation else {
                        result = .noRecentEdits(isComplete: true)
                        break
                    }
                    switch try await client.readTurnChanges(threadID: conversation) {
                    case .ready(let changes): result = .ready(await ChangeReviewPreparation.prepare(changes, revision: revision))
                    case .noRecentEdits(let complete): result = .noRecentEdits(isComplete: complete)
                    }
                case .git(let source):
                    async let fresh: Checkouts? = discovering
                        ? await Self.discoverCheckouts(client: client, conversation: conversation, directory: directory) : nil
                    let target = if let chosen { chosen } else { Self.defaultRoot(in: discovering ? await fresh ?? .unknown : known) }
                    reviewed = target
                    async let read = client.readChanges(directory: target ?? directory, source: source)
                    discovered = await fresh
                    switch try await read {
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
            if case .failed(let message) = result { self.logger.notice("Reading changes failed: \(message)") }
            if case .git = mode {
                self.root = reviewed
                if let discovered {
                    self.checkouts = discovered
                    self.discoversCheckouts = false
                }
            }
            self.state = result
            self.isRefreshing = false
        }
    }

    private nonisolated static func discoverCheckouts(client: GatewayClient, conversation: String?,
                                                      directory: String) async -> Checkouts {
        do {
            return .found(try await client.readCheckouts(threadID: conversation, directory: directory))
        } catch {
            AppLogger(category: "ChangeReview").notice("Finding checkouts failed: \(error.localizedDescription)")
            return .failed
        }
    }

    private nonisolated static func defaultRoot(in checkouts: Checkouts) -> String? {
        guard case .found(let discovery) = checkouts else { return nil }
        return discovery.defaultRoot
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
        case .turn(_, let startedAt): "Turn at \(Self.formattedStart(startedAt))"
        }
    }

    static func formattedStart(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                              : date.formatted(date: .abbreviated, time: .shortened)
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
        case .turn(_, let startedAt): "the edits of the turn that started at \(Self.formattedStart(startedAt))"
        }
        return "\(changes) in \(anchor.root)"
    }

    private static func rank(_ comparison: ReviewComparison) -> Int {
        switch comparison {
        case .git(let source): ChangeSource.allCases.firstIndex(of: source) ?? 0
        case .turn: ChangeSource.allCases.count
        }
    }

    private static func turnStart(_ comparison: ReviewComparison) -> Date {
        if case .turn(_, let startedAt) = comparison { startedAt } else { .distantPast }
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
    func showPreview(_ state: State, mode: Mode = .git(defaultSource), checkouts: Checkouts = .unknown, root: String? = nil,
                     notes: [ReviewNote] = []) {
        self.state = state
        self.mode = mode
        self.checkouts = checkouts
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
