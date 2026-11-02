import Foundation
import Observation

@MainActor
@Observable
final class ChangeReviewModel {
    enum State {
        case loading
        case ready(ChangeReview)
        case unavailable(ChangeUnavailability)
        case failed(String)
    }

    let directory: String
    private(set) var source: ChangeSource = .uncommitted
    private(set) var state: State = .loading
    private(set) var isRefreshing = false
    private(set) var collapsedFiles: [ReviewedFile.ID: Bool] = [:]
    private(set) var notes: [ReviewNote.Anchor: ReviewNoteDraft] = [:]
    var focusedNote: ReviewNote.Anchor?
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")

    init(directory: String, client: GatewayClient) {
        self.directory = directory
        self.client = client
    }

    func reviews(directory: String?, through client: GatewayClient) -> Bool {
        self.directory == directory && self.client === client
    }

    var selectedSource: ChangeSource {
        get { source }
        set { select(newValue) }
    }

    func select(_ source: ChangeSource) {
        guard source != self.source else { return }
        self.source = source
        state = .loading
        refresh()
    }

    func refresh() {
        loading?.cancel()
        revision += 1
        let revision = revision
        let source = source
        isRefreshing = true
        loading = Task { [weak self, client, directory] in
            let result: State
            do {
                switch try await client.readChanges(directory: directory, source: source) {
                case .ready(let snapshot): result = .ready(await ChangeReviewPreparation.prepare(snapshot, revision: revision))
                case .unavailable(let reason): result = .unavailable(reason)
                }
            } catch is CancellationError {
                return
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard let self, self.revision == revision, !Task.isCancelled else { return }
            if case .failed(let message) = result { self.logger.notice("Reading \(source.rawValue) changes failed: \(message)") }
            self.state = result
            self.isRefreshing = false
        }
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
        notes.keys.count(where: { $0.source == file.source && $0.path == file.path })
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
            .sorted { ($0.anchor.path, $0.anchor.line) < ($1.anchor.path, $1.anchor.line) }
    }

    func commentsPrompt() -> String? {
        let sources = ChangeSource.allCases
        let order: [String: Int]
        if case .ready(let review) = state {
            order = Dictionary(review.files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            order = [:]
        }
        let sorted = notes.values.map { ReviewNote(anchor: $0.anchor, text: $0.text) }.sorted {
            let left = (sources.firstIndex(of: $0.anchor.source) ?? 0, order[$0.anchor.path] ?? .max, $0.anchor.path, $0.anchor.line)
            let right = (sources.firstIndex(of: $1.anchor.source) ?? 0, order[$1.anchor.path] ?? .max, $1.anchor.path, $1.anchor.line)
            return left < right
        }
        return ReviewNote.prompt(sorted, scope: scope(of:))
    }

    func clearNotes() {
        notes = [:]
        focusedNote = nil
    }

    private func scope(of source: ChangeSource) -> String {
        switch source {
        case .uncommitted: "the uncommitted changes"
        case .staged: "the staged changes"
        case .unstaged: "the unstaged changes"
        case .branch:
            if case .ready(let review) = state, review.source == .branch, let base = review.base {
                "this branch's changes against \(base)"
            } else {
                "this branch's changes"
            }
        }
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
    func showPreview(_ state: State, notes: [ReviewNote] = []) {
        self.state = state
        if case .ready(let review) = state { source = review.source }
        isRefreshing = false
        self.notes = Dictionary(uniqueKeysWithValues: notes.map { note in
            let draft = ReviewNoteDraft(anchor: note.anchor)
            draft.text = note.text
            return (note.anchor, draft)
        })
    }
}
#endif
