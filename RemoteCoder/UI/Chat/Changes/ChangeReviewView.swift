import SwiftUI

struct ChangeReviewView: View {
    let model: ChangeReviewModel
    let remoteHomePath: String?
    let canAddComments: Bool
    let onAddComments: (String) -> Bool

    var body: some View {
        ChangeReviewContent(model: model, remoteHomePath: remoteHomePath)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ChangeReviewCommentBar(model: model, canAddComments: canAddComments, onAddComments: onAddComments)
            }
    }
}

private struct ChangeReviewContent: View {
    let model: ChangeReviewModel
    let remoteHomePath: String?

    var body: some View {
        switch model.state {
        case .loading:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChangeReviewHeader(model: model, review: nil, remoteHomePath: remoteHomePath)
                    ChangeReviewPlaceholder()
                }
            }
        case .ready(let review) where review.files.isEmpty && review.unlistedFiles == 0:
            ChangeReviewMessage(model: model, review: review, remoteHomePath: remoteHomePath) {
                VStack(spacing: 0) {
                    ContentUnavailableView(model.mode.emptyTitle, systemImage: "checkmark.circle",
                                           description: Text(model.mode.emptyDescription))
                        .frame(maxHeight: .infinity)
                    ChangeReviewNotices(review: review, remoteHomePath: remoteHomePath)
                }
            }
        case .ready(let review):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ChangeReviewHeader(model: model, review: review, remoteHomePath: remoteHomePath)
                    ForEach(review.files) { file in
                        if case .turn = review.scope, file.isFirstInRoot {
                            ChangeReviewRootHeader(root: file.root, remoteHomePath: remoteHomePath)
                        }
                        DiffFileSection(model: model, file: file)
                    }
                    ChangeReviewFooter(model: model, review: review, remoteHomePath: remoteHomePath)
                }
            }
            .accessibilityIdentifier("change-review-files")
        case .unavailable(let reason):
            ChangeReviewMessage(model: model, review: nil, remoteHomePath: remoteHomePath) {
                ChangeReviewUnavailable(reason: reason, folder: WorkingDirectoryPathFormatter.displayPath(
                    model.root ?? model.directory, remoteHomePath: remoteHomePath))
            }
        case .noRecentEdits(let isComplete):
            ChangeReviewMessage(model: model, review: nil, remoteHomePath: remoteHomePath) {
                ContentUnavailableView("No Recent Edits", systemImage: "clock",
                                       description: isComplete ? nil : Text("Some history couldn’t be read, so edits may be missing."))
            }
        case .failed(let message):
            ChangeReviewMessage(model: model, review: nil, remoteHomePath: remoteHomePath) {
                ContentUnavailableView {
                    Label("Couldn’t Read Changes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: model.refresh)
                        .appButtonFeedback()
                }
            }
        }
    }
}

private struct ChangeReviewMessage<Message: View>: View {
    let model: ChangeReviewModel
    let review: ChangeReview?
    let remoteHomePath: String?
    @ViewBuilder let message: Message

    var body: some View {
        let notes = model.notes(outside: review)
        if notes.isEmpty {
            VStack(spacing: 0) {
                ChangeReviewHeader(model: model, review: review, remoteHomePath: remoteHomePath)
                message.frame(maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChangeReviewHeader(model: model, review: review, remoteHomePath: remoteHomePath)
                    message.padding(.vertical, 24)
                    ReviewNotesOutsideComparison(model: model, drafts: notes)
                }
            }
        }
    }
}

private struct ReviewNotesOutsideComparison: View {
    let model: ChangeReviewModel
    let drafts: [ReviewNoteDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Comments on Lines Not Shown")
                .scaledFont(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            ForEach(drafts) { draft in
                VStack(alignment: .leading, spacing: 4) {
                    Text(location(of: draft.anchor))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(draft.anchor.excerpt.trimmingCharacters(in: .whitespaces))
                        .scaledFont(TypeMetrics.code)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                ReviewNoteEditor(model: model, draft: draft)
            }
        }
    }

    private func location(of anchor: ReviewNote.Anchor) -> String {
        "\(model.title(of: anchor.comparison)) · \((anchor.root as NSString).lastPathComponent) · \(anchor.path):\(anchor.line)"
    }
}

private struct ChangeReviewRootHeader: View {
    let root: String
    let remoteHomePath: String?

    var body: some View {
        Label(WorkingDirectoryPathFormatter.displayPath(root, remoteHomePath: remoteHomePath), systemImage: "folder")
            .scaledFont(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }
}

private struct ChangeReviewHeader: View {
    @Bindable var model: ChangeReviewModel
    let review: ChangeReview?
    let remoteHomePath: String?

    var body: some View {
        HStack(spacing: 10) {
            AppMenu {
                Picker("Compare", selection: $model.selectedMode) {
                    ForEach(ChangeReviewModel.Mode.all, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if case .git = model.mode, let checkouts = model.summary?.summary {
                    CheckoutPicker(model: model, checkouts: checkouts, remoteHomePath: remoteHomePath)
                }
                if let review, !review.files.isEmpty {
                    Divider()
                    Button("Collapse All Files", systemImage: "rectangle.compress.vertical") {
                        model.setAllCollapsed(true, in: review)
                    }
                    Button("Expand All Files", systemImage: "rectangle.expand.vertical") {
                        model.setAllCollapsed(false, in: review)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.mode.title).fontWeight(.semibold)
                    if case .git = model.mode {
                        if let root = model.root {
                            Text((root as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(TypeMetrics.symbol(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .scaledFont(.headline)
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("change-review-source")

            if let review, !review.files.isEmpty || review.unlistedFiles > 0 {
                ChangeReviewSummary(totals: review.totals)
            }
            Spacer(minLength: 0)
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                    .labelStyle(.iconOnly)
                    .appButtonFeedback()
                    .tooltip("Read the changes again")
                    .accessibilityIdentifier("change-review-refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct CheckoutPicker: View {
    @Bindable var model: ChangeReviewModel
    let checkouts: PreparedChangeSummary
    let remoteHomePath: String?

    var body: some View {
        if !checkouts.workedIn.isEmpty {
            Section("Worked In") {
                Picker("Worked In", selection: $model.selectedRoot) {
                    ForEach(checkouts.workedIn, id: \.root) { checkout in
                        Group {
                            Label(displayPath(checkout.root), systemImage: symbol(for: checkout.evidence))
                            if let totals = checkout.totals {
                                if totals.files == 0 { Text("No changes") } else { Text("\(totals.files) files") }
                            } else {
                                Text("Couldn't read")
                            }
                        }
                        .tag(Optional(checkout.root))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        if !checkouts.inFolder.isEmpty {
            Picker(selection: $model.selectedRoot) {
                ForEach(checkouts.inFolder, id: \.self) { root in
                    Text(displayPath(root)).tag(Optional(root))
                }
            } label: {
                Label("In \((model.directory as NSString).lastPathComponent)", systemImage: "folder")
            }
            .pickerStyle(.menu)
        }
        if !checkouts.complete {
            Text("Some checkouts may be missing.")
        }
    }

    private func displayPath(_ root: String) -> String {
        WorkingDirectoryPathFormatter.displayPath(root, remoteHomePath: remoteHomePath)
    }

    private func symbol(for evidence: Set<ChangeSummary.Evidence>) -> String {
        if evidence.contains(.edited) { "pencil" } else if evidence.contains(.command) { "terminal" } else { "folder" }
    }
}

private struct ChangeReviewSummary: View {
    let totals: ChangeTotals

    var body: some View {
        HStack(spacing: 6) {
            FileCount(files: totals.files)
                .foregroundStyle(.secondary)
            if let lines = totals.lines {
                DiffCounts(additions: lines.additions, deletions: lines.deletions)
            }
        }
        .scaledFont(.subheadline.monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

private struct ChangeReviewFooter: View {
    let model: ChangeReviewModel
    let review: ChangeReview
    let remoteHomePath: String?

    var body: some View {
        let outside = model.notes(outside: review)
        VStack(alignment: .leading, spacing: 0) {
            if !outside.isEmpty {
                ReviewNotesOutsideComparison(model: model, drafts: outside)
            }
            ChangeReviewNotices(review: review, remoteHomePath: remoteHomePath)
        }
    }
}

private struct ChangeReviewNotices: View {
    let review: ChangeReview
    let remoteHomePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .turn(let turn, let commands, let omittedAgents) = review.scope {
                if !turn.latest {
                    Text("Later turns made no edits.")
                }
                if commands > 0 {
                    Text(commands == 1 ? "Also ran 1 command; files it changed aren’t listed."
                                       : "Also ran \(commands) commands; files they changed aren’t listed.")
                }
                if omittedAgents > 0 {
                    Text(omittedAgents == 1 ? "Edits by 1 agent aren’t included." : "Edits by \(omittedAgents) agents aren’t included.")
                }
            }
            if review.unlistedFiles > 0 {
                Text(unlistedNotice)
            } else if !review.isComplete {
                if case .turn = review.scope {
                    Text("Some history couldn’t be read, so edits may be missing.")
                } else {
                    Text("This comparison is too large to read completely.")
                }
            }
            Text(detail).foregroundStyle(.tertiary)
        }
        .scaledFont(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var unlistedNotice: String {
        switch (review.files.isEmpty, review.unlistedFiles) {
        case (true, 1): "1 file isn’t shown."
        case (true, let count): "\(count) files aren’t shown."
        case (false, 1): "1 more file isn’t shown."
        case (false, let count): "\(count) more files aren’t shown."
        }
    }

    private var detail: String {
        let time = review.capturedAt.formatted(date: .omitted, time: .shortened)
        switch review.scope {
        case .git(let source, let root, let branch, let base):
            let root = WorkingDirectoryPathFormatter.displayPath(root, remoteHomePath: remoteHomePath)
            let branch = branch ?? "Detached HEAD"
            let against = source == .branch ? base.map { " against \($0)" } ?? "" : ""
            return "\(branch)\(against) · \(root) · \(time)"
        case .turn(let turn, _, _):
            let start = ChangeReviewModel.formattedStart(turn.startedAt)
            return turn.running ? "Turn started \(start), still running · \(time)" : "Turn started \(start) · \(time)"
        }
    }
}

private struct ChangeReviewUnavailable: View {
    let reason: ChangeUnavailability
    let folder: String

    var body: some View {
        switch reason {
        case .missingDirectory:
            ContentUnavailableView("Folder Not Found", systemImage: "folder.badge.questionmark",
                                   description: Text("\(folder) doesn’t exist on this host."))
        case .notRepository:
            ContentUnavailableView("Not a Git Repository", systemImage: "folder",
                                   description: Text("\(folder) isn’t inside a Git repository."))
        case .noBaseBranch:
            ContentUnavailableView("No Base Branch", systemImage: "arrow.triangle.branch",
                                   description: Text("There’s no main or master branch to compare with."))
        case .noMergeBase:
            ContentUnavailableView("No Shared History", systemImage: "arrow.triangle.branch",
                                   description: Text("This branch has no commit in common with its base."))
        }
    }
}

private struct ChangeReviewCommentBar: View {
    let model: ChangeReviewModel
    let canAddComments: Bool
    let onAddComments: (String) -> Bool

    var body: some View {
        let count = model.writtenNoteCount
        Group {
            if count > 0 {
                HStack(spacing: 12) {
                    Button("Discard", systemImage: "trash", role: .destructive, action: model.clearNotes)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tooltip("Discard the comments")
                    Button {
                        guard let prompt = model.commentsPrompt(), onAddComments(prompt) else { return }
                        model.clearNotes()
                    } label: {
                        Label(count == 1 ? "Add Comment to Message" : "Add \(count) Comments to Message", systemImage: "text.bubble")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAddComments)
                    .accessibilityIdentifier("change-review-add-comments")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: count > 0)
    }
}

struct FileCount: View {
    let files: Int

    var body: some View {
        Text(files == 1 ? "1 file" : "\(files) files")
    }
}

struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(DiffPalette.added)
            Text("−\(deletions)").foregroundStyle(DiffPalette.removed)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) added, \(deletions) removed")
    }
}

private struct ChangeReviewPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<4, id: \.self) { file in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 14)
                    ForEach(0..<(file.isMultiple(of: 2) ? 5 : 3), id: \.self) { line in
                        RoundedRectangle(cornerRadius: 3).frame(width: CGFloat(120 + (line * 47) % 160), height: 10)
                    }
                }
            }
        }
        .foregroundStyle(.quaternary)
        .shimmer(isActive: true)
        .padding(16)
        .accessibilityLabel("Loading changes")
    }
}

extension ChangeReviewModel.Mode {
    var title: String {
        switch self {
        case .lastTurn: "Last Turn"
        case .git(let source): source.title
        }
    }

    var systemImage: String {
        switch self {
        case .lastTurn: "clock.arrow.circlepath"
        case .git(let source): source.systemImage
        }
    }

    var emptyTitle: String {
        switch self {
        case .lastTurn: "No Net Changes"
        case .git(let source): source.emptyTitle
        }
    }

    var emptyDescription: String {
        switch self {
        case .lastTurn: "The last turn’s edits cancel each other out."
        case .git(let source): source.emptyDescription
        }
    }
}

extension ChangeSource {
    var emptyTitle: String {
        switch self {
        case .uncommitted, .staged, .unstaged: "No Changes"
        case .branch: "No Branch Changes"
        }
    }

    var emptyDescription: String {
        switch self {
        case .uncommitted: "The working tree matches the last commit."
        case .staged: "Nothing is staged."
        case .unstaged: "Everything is staged."
        case .branch: "This branch matches its base."
        }
    }

    var title: String {
        switch self {
        case .uncommitted: "Uncommitted"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .branch: "Branch"
        }
    }

    var systemImage: String {
        switch self {
        case .uncommitted: "square.and.pencil"
        case .staged: "tray.full"
        case .unstaged: "tray"
        case .branch: "arrow.triangle.branch"
        }
    }
}
