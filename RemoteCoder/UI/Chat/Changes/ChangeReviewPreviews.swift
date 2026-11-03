#if DEBUG
import SwiftUI

enum ChangeReviewFixture {
    static let patches: [(String, Int, Int, ChangeSnapshot.Omission?)] = [
        ("""
        diff --git a/RemoteCoder/Chat/ChatScreenModel.swift b/RemoteCoder/Chat/ChatScreenModel.swift
        index 4cb29ea..6addb9b 100644
        --- a/RemoteCoder/Chat/ChatScreenModel.swift
        +++ b/RemoteCoder/Chat/ChatScreenModel.swift
        @@ -1366,11 +1366,22 @@ final class ChatScreenModel: HistoryEdgeHost {
             private func attach(_ claim: SharedItemsInbox.Claim, to draft: ComposerDraft) {
                 guard target.acceptsWork else { return }
                 importFiles(claim.files.map { file in .inOwnDirectory { file } }, for: draft)
        -        switch ComposerPastedText(claim.text.joined(separator: "\\n")) {
        -        case .attachment(let text): drafts.setAttachments(draft.attachments + [.text(text)], in: draft)
        -        case .inline(let text): drafts.document(for: draft).edit(.insert(.init(runs: [.text(text)])))
        -        case nil: break
        -        }
        +        insertPastedText(claim.text.joined(separator: "\\n"), into: draft)
        +    }
        +
        +    func insertReviewComments(_ text: String) -> Bool {
        +        guard target.acceptsWork, acceptsConversationInput, let draft = currentDraft else { return false }
        +        insertPastedText(text, into: draft)
        +        return true
             }
        \u{20}
        @@ -1402,7 +1413,7 @@ final class ChatScreenModel: HistoryEdgeHost {
             func resumeStagedUploads() {
                 guard target.acceptsWork, let draft = currentDraft else { return }
        -        target.fileImports.resume(in: draft)
        +        target.fileImports.resume(in: draft, priority: .userInitiated)
             }

        """, 13, 6, nil),
        ("""
        diff --git a/docs/change-review.md b/docs/change-review.md
        new file mode 100644
        index 0000000..ce01362
        --- /dev/null
        +++ b/docs/change-review.md
        @@ -0,0 +1,4 @@
        +# Change review
        +
        +The gateway reads one Git comparison per request and the app
        +renders it per file, with comments that go back to the agent.

        """, 4, 0, nil),
        ("""
        diff --git a/Sources/Legacy.swift b/Sources/Legacy.swift
        deleted file mode 100644
        index ce01362..0000000
        --- a/Sources/Legacy.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -struct Legacy {
        -    let value = 42
        -}

        """, 0, 3, nil),
        ("""
        diff --git a/Assets/icon.png b/Assets/icon.png
        index 88768ef..f68ed80 100644
        Binary files a/Assets/icon.png and b/Assets/icon.png differ

        """, 0, 0, nil),
        ("""
        diff --git a/web-client/package-lock.json b/web-client/package-lock.json
        index 1a2b3c4..5d6e7f8 100644
        --- a/web-client/package-lock.json
        +++ b/web-client/package-lock.json

        """, 4120, 3870, ChangeSnapshot.Omission(reason: .fileTooLarge, patchBytes: 612_000)),
        ("""
        * Unmerged path Config/RemoteCoder.xcconfig

        """, 0, 0, nil),
    ]

    static var snapshot: ChangeSnapshot {
        let files = patches.map { patch, additions, deletions, omission in
            ChangeSnapshot.File(patch: patch, additions: additions, deletions: deletions, omitted: omission, replacedInvalidUtf8: false)
        }
        return ChangeSnapshot(source: .uncommitted, root: "/Users/emil/RemoteCoder", branch: "feat/diff-review",
                              base: nil, capturedAtMs: 1_793_631_600_000, files: files, unlistedFiles: 0, complete: true)
    }

    static var review: ChangeReview { ChangeReviewPreparation.review(of: snapshot, revision: 1) }

    static var emphasis: ChangeReview {
        let patch = """
        diff --git a/RemoteCoder/Chat/ChatScreenModel.swift b/RemoteCoder/Chat/ChatScreenModel.swift
        index 4cb29ea..6addb9b 100644
        --- a/RemoteCoder/Chat/ChatScreenModel.swift
        +++ b/RemoteCoder/Chat/ChatScreenModel.swift
        @@ -1402,7 +1413,7 @@ final class ChatScreenModel: HistoryEdgeHost {
             func resumeStagedUploads() {
                 guard target.acceptsWork, let draft = currentDraft else { return }
        -        target.fileImports.resume(in: draft)
        +        target.fileImports.resume(in: draft, priority: .userInitiated)
             }

        """
        let file = ChangeSnapshot.File(patch: patch, additions: 1, deletions: 1, omitted: nil, replacedInvalidUtf8: false)
        return ChangeReviewPreparation.review(of: ChangeSnapshot(
            source: .branch, root: "/Users/emil/RemoteCoder", branch: "feat/diff-review",
            base: "origin/main", capturedAtMs: 1_793_631_600_000,
            files: [file], unlistedFiles: 0, complete: true), revision: 1)
    }

    static let worktree = "/Users/emil/stretch/care.ai.worktrees/codeact"

    static var lastTurn: ChangeReview {
        let notes = """
        diff --git a/todo.md b/todo.md
        --- a/todo.md
        +++ b/todo.md
        @@ -1,3 +1,3 @@
         # Today
        -- Review the CodeAct branch
        +- [x] Review the CodeAct branch
         - Ship 3.91

        """
        let entries: [(root: String, patch: (String, Int, Int, ChangeSnapshot.Omission?))] = [
            (worktree, patches[0]), (worktree, patches[1]), ("/Users/emil/notes", (notes, 1, 1, nil)),
        ]
        let files = entries.map { entry in
            TurnChanges.File(root: entry.root, change: ChangeSnapshot.File(patch: entry.patch.0, additions: entry.patch.1,
                                                                           deletions: entry.patch.2, omitted: entry.patch.3,
                                                                           replacedInvalidUtf8: false))
        }
        return ChangeReviewPreparation.review(of: TurnChanges(
            window: .turn(TurnChanges.Turn(id: "turn-1", startedAtMs: 1_793_631_000_000, running: false, latest: false)),
            files: files, unlistedFiles: 0, commands: 7, omittedAgents: 1, complete: true, capturedAtMs: 1_793_631_600_000), revision: 1)
    }

    static var worktreeReview: ChangeReview {
        ChangeReviewPreparation.review(of: ChangeSnapshot(
            source: .uncommitted, root: worktree, branch: "feat/codeact", base: nil, capturedAtMs: 1_793_631_600_000,
            files: Array(snapshot.files.prefix(2)), unlistedFiles: 0, complete: true), revision: 1)
    }

    static var summary: PreparedChangeSummary {
        let data = Data(#"{"workedIn":[{"root":"/Users/emil/stretch/care.ai.worktrees/codeact","evidence":["edited","command"],"status":"ready","snapshot":{"source":"branch","root":"/Users/emil/stretch/care.ai.worktrees/codeact","files":[],"unlistedFiles":2,"complete":false,"capturedAtMs":0}},{"root":"/Users/emil/stretch/care.ai","evidence":["command"],"status":"failed"}],"inFolder":["/Users/emil/stretch/kartan"],"complete":false}"#.utf8)
        do {
            return PreparedChangeSummary(try JSONDecoder().decode(ChangeSummary.self, from: data))
        } catch {
            preconditionFailure("Invalid preview summary: \(error)")
        }
    }

    @MainActor
    static func model(_ state: ChangeReviewModel.State, view: ChangesView = .git(.uncommitted),
                      summary: PreparedChangeSummary? = nil, root: String? = nil,
                      notes: [ReviewNote] = []) -> ChangeReviewModel? {
        guard let client = client() else { return nil }
        let summaryModel = summaryModel(view: view, summary: summary, client: client)
        let model = ChangeReviewModel(conversation: "preview", directory: "/Users/emil/stretch", client: client,
                                      summary: summaryModel)
        model.showPreview(state, view: view, root: root, notes: notes)
        return model
    }

    static func client() -> GatewayClient? {
        let host = GatewayHostConfiguration(id: UUID(), name: "Preview", hostname: "127.0.0.1", port: 1,
                                            authToken: "preview", transport: .trustedNetwork)
        return try? GatewayClient(host: host, routes: nil)
    }

    @MainActor
    static func summaryModel(view: ChangesView, summary: PreparedChangeSummary?, client: GatewayClient) -> ChangeSummaryModel {
        let views = ConversationChangesViews(read: { view }, write: { _ in }, startPoints: {
            ChangesStartPoints(prompts: [
                .init(anchor: ChangesAnchor(turnID: "turn-2", boundary: .start), preview: "Ship the changes pill", date: .now),
                .init(anchor: ChangesAnchor(turnID: "turn-1", boundary: .start), preview: "Review the CodeAct branch",
                      date: .now.addingTimeInterval(-1_800)),
            ])
        })
        let summaryModel = ChangeSummaryModel(conversation: "preview", directory: "/Users/emil/stretch", client: client, views: views)
        summaryModel.showPreview(summary, view: view)
        return summaryModel
    }

    static var comment: ReviewNote {
        ReviewNote(anchor: ReviewNote.Anchor(comparison: .git(.uncommitted), root: "/Users/emil/RemoteCoder",
                                             path: "RemoteCoder/Chat/ChatScreenModel.swift", line: 1372, side: .addition,
                                             excerpt: "    func insertReviewComments(_ text: String) -> Bool {"),
                   text: "Return the outcome so the sheet only closes when the comments landed.")
    }

    static var stagedComment: ReviewNote {
        ReviewNote(anchor: ReviewNote.Anchor(comparison: .git(.staged), root: "/Users/emil/RemoteCoder", path: "docs/change-review.md",
                                             line: 3, side: .addition,
                                             excerpt: "The gateway reads one Git comparison per request and the app"),
                   text: "Say what happens to untracked files.")
    }
}

private struct ChangeReviewPreview: View {
    @State private var model: ChangeReviewModel?
    @State private var theme = AppThemeStore()

    init(_ state: ChangeReviewModel.State, view: ChangesView = .git(.uncommitted),
         summary: PreparedChangeSummary? = nil, root: String? = nil, notes: [ReviewNote] = [],
         collapsing paths: Set<String> = []) {
        let model = ChangeReviewFixture.model(state, view: view, summary: summary, root: root, notes: notes)
        if let model, case .ready(let review) = state {
            for file in review.files where paths.contains(file.path) { model.toggleCollapsed(file) }
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        if let model {
            NavigationStack {
                ChangeReviewView(model: model, remoteHomePath: "/Users/emil", canAddComments: true, onAddComments: { _ in true })
                    .navigationTitle("Changes")
                    .inlineNavigationTitle()
            }
            .environment(theme)
        } else {
            Text("Could not create the preview gateway client.")
        }
    }
}

#Preview("A · Ready") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.review))
}

#Preview("B · Comment") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.review), notes: [ChangeReviewFixture.comment])
}

#Preview("C · Dark") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.review), notes: [ChangeReviewFixture.comment])
        .preferredColorScheme(.dark)
}

#Preview("D · Loading") {
    ChangeReviewPreview(.loading)
}

#Preview("E · Empty") {
    ChangeReviewPreview(.ready(ChangeReviewPreparation.review(of: ChangeSnapshot(
        source: .uncommitted, root: "/Users/emil/RemoteCoder", branch: "main", base: nil,
        capturedAtMs: 1_793_631_600_000, files: [], unlistedFiles: 0, complete: true), revision: 1)),
                        notes: [ChangeReviewFixture.stagedComment])
}

#Preview("F · Not a repository") {
    ChangeReviewPreview(.unavailable(.notRepository))
}

#Preview("G · File states") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.review), collapsing: ["RemoteCoder/Chat/ChatScreenModel.swift"])
}

#Preview("H · Word emphasis") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.emphasis))
}

#Preview("I · Last turn") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.lastTurn), view: .lastTurn,
                        collapsing: ["RemoteCoder/Chat/ChatScreenModel.swift"])
}

#Preview("J · Worktree checkout") {
    ChangeReviewPreview(.ready(ChangeReviewFixture.worktreeReview), summary: ChangeReviewFixture.summary,
                        root: ChangeReviewFixture.worktree)
}

#Preview("K · No recent edits") {
    ChangeReviewPreview(.noRecentEdits(isComplete: true), view: .lastTurn)
}

#Preview("L · No net changes") {
    ChangeReviewPreview(.ready(ChangeReviewPreparation.review(of: TurnChanges(
        window: .turn(TurnChanges.Turn(id: "turn-2", startedAtMs: 1_793_631_000_000, running: false, latest: true)),
        files: [], unlistedFiles: 0, commands: 3, omittedAgents: 1, complete: false, capturedAtMs: 1_793_631_600_000), revision: 1)),
                        view: .lastTurn)
}

#Preview("L2 · Start point not found") {
    ChangeReviewPreview(.anchorMissing(isComplete: true), view: .since(ChangesAnchor(turnID: "turn-1", boundary: .end)))
}

#Preview("M · Checkouts not loaded") {
    ChangeReviewPreview(.unavailable(.notRepository))
}

#Preview("N · Checkout options") {
    if let model = ChangeReviewFixture.model(.ready(ChangeReviewFixture.worktreeReview),
                                             summary: ChangeReviewFixture.summary, root: ChangeReviewFixture.worktree) {
        Form {
            CheckoutPicker(model: model, checkouts: ChangeReviewFixture.summary, remoteHomePath: "/Users/emil")
        }
    }
}
#endif
