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
                    ChangeReviewHeader(model: model, review: nil)
                    ChangeReviewPlaceholder()
                }
            }
        case .ready(let review) where review.files.isEmpty && review.unlistedFiles == 0:
            ChangeReviewMessage(model: model, review: review) {
                ContentUnavailableView(model.source.emptyTitle, systemImage: "checkmark.circle",
                                       description: Text(model.source.emptyDescription))
            }
        case .ready(let review):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ChangeReviewHeader(model: model, review: review)
                    ForEach(review.files) { file in
                        DiffFileSection(model: model, file: file)
                    }
                    ChangeReviewFooter(model: model, review: review, remoteHomePath: remoteHomePath)
                }
            }
            .accessibilityIdentifier("change-review-files")
        case .unavailable(let reason):
            ChangeReviewMessage(model: model, review: nil) {
                ChangeReviewUnavailable(reason: reason, folder: WorkingDirectoryPathFormatter.displayPath(
                    model.directory, remoteHomePath: remoteHomePath))
            }
        case .failed(let message):
            ChangeReviewMessage(model: model, review: nil) {
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
    @ViewBuilder let message: Message

    var body: some View {
        let notes = model.notes(outside: review)
        if notes.isEmpty {
            VStack(spacing: 0) {
                ChangeReviewHeader(model: model, review: review)
                message.frame(maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChangeReviewHeader(model: model, review: review)
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
        let place = "\(anchor.path):\(anchor.line)"
        return anchor.source == model.source ? place : "\(anchor.source.title) · \(place)"
    }
}

private struct ChangeReviewHeader: View {
    @Bindable var model: ChangeReviewModel
    let review: ChangeReview?

    var body: some View {
        HStack(spacing: 10) {
            AppMenu {
                Picker("Compare", selection: $model.selectedSource) {
                    ForEach(ChangeSource.allCases, id: \.self) { source in
                        Label(source.title, systemImage: source.systemImage).tag(source)
                    }
                }
                .pickerStyle(.inline)
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
                    Text(model.source.title).fontWeight(.semibold)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(TypeMetrics.symbol(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .scaledFont(.headline)
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("change-review-source")

            if let review, !review.files.isEmpty || review.unlistedFiles > 0 {
                ChangeReviewSummary(fileCount: review.files.count + review.unlistedFiles, lineCounts: review.lineCounts)
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

private struct ChangeReviewSummary: View {
    let fileCount: Int
    let lineCounts: ChangeReview.LineCounts?

    var body: some View {
        HStack(spacing: 6) {
            Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                .foregroundStyle(.secondary)
            if let lineCounts {
                DiffCounts(additions: lineCounts.additions, deletions: lineCounts.deletions)
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
            VStack(alignment: .leading, spacing: 6) {
                if review.unlistedFiles > 0 {
                    Text(review.unlistedFiles == 1 ? "1 more file isn’t shown." : "\(review.unlistedFiles) more files aren’t shown.")
                } else if !review.isComplete {
                    Text("This comparison is too large to read completely.")
                }
                Text(detail).foregroundStyle(.tertiary)
            }
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .padding(16)
        }
    }

    private var detail: String {
        let root = WorkingDirectoryPathFormatter.displayPath(review.root, remoteHomePath: remoteHomePath)
        let time = review.capturedAt.formatted(date: .omitted, time: .shortened)
        let branch = review.branch ?? "Detached HEAD"
        switch review.source {
        case .branch:
            let base = review.base.map { " against \($0)" } ?? ""
            return "\(branch)\(base) · \(root) · \(time)"
        case .uncommitted, .staged, .unstaged:
            return "\(branch) · \(root) · \(time)"
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
