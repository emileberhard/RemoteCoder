import SwiftUI

struct DiffFileSection: View, Equatable {
    let model: ChangeReviewModel
    let file: ReviewedFile

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.file == rhs.file
    }

    var body: some View {
        let collapsed = model.isCollapsed(file)
        Section {
            if !collapsed {
                if file.rows.isEmpty {
                    DiffFileNotice(file: file)
                } else {
                    let digits = String(file.rows.lazy.compactMap { $0.newNumber ?? $0.oldNumber }.max() ?? 0).count
                    ForEach(file.rows) { row in
                        DiffRowView(model: model, path: file.path, row: row, anchor: file.anchor(for: row), gutterDigits: digits)
                    }
                    if file.replacedInvalidUTF8 {
                        DiffNoticeText("Some bytes aren’t valid UTF-8 and show as �.")
                    }
                }
            }
        } header: {
            DiffFileHeader(file: file, isCollapsed: collapsed, noteCount: model.noteCount(in: file)) {
                model.toggleCollapsed(file)
            }
        }
    }
}

private struct DiffFileHeader: View {
    let file: ReviewedFile
    let isCollapsed: Bool
    let noteCount: Int
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .scaledFont(TypeMetrics.symbol(12, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    statusBadge
                    path
                    Spacer(minLength: 4)
                    if noteCount > 0 {
                        Label("\(noteCount)", systemImage: "text.bubble.fill")
                            .scaledFont(.caption.monospacedDigit())
                            .foregroundStyle(.tint)
                    }
                    if file.hasLineCounts {
                        DiffCounts(additions: file.additions, deletions: file.deletions)
                            .scaledFont(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appButtonFeedback()
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            AppMenu(trigger: .icon) {
                Button("Copy Path", systemImage: "doc.on.doc") { HapticService.shared.copy(file.path) }
                Button(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                       action: toggle)
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(TypeMetrics.symbol(14, weight: .semibold))
                    .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                    .contentShape(Rectangle())
            }
            .tooltip("File actions")
            .accessibilityLabel("File actions")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var path: some View {
        let name = (file.path as NSString).lastPathComponent
        let directory = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: 0) {
            if !directory.isEmpty {
                Text(directory + "/").foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(0)
            }
            Text(name).fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .scaledFont(.subheadline)
        .foregroundStyle(.primary)
    }

    private var statusBadge: some View {
        let (letter, color): (String, Color) = switch file.status {
        case _ where file.isConflict: ("!", .orange)
        case .added: ("A", .green)
        case .deleted: ("D", .red)
        case .modified: ("M", .blue)
        case .renamed: ("R", .purple)
        case .copied: ("C", .purple)
        }
        return Text(letter)
            .scaledFont(.caption2.weight(.bold).monospaced())
            .foregroundStyle(color)
            .scaledFrame(width: 18, height: 18)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    private var accessibilitySummary: String {
        var parts = [file.path, statusDescription]
        if file.hasLineCounts { parts.append("\(file.additions) added, \(file.deletions) removed") }
        if noteCount > 0 { parts.append(noteCount == 1 ? "1 comment" : "\(noteCount) comments") }
        return parts.joined(separator: ", ")
    }

    private var statusDescription: String {
        if file.isConflict { return "conflict" }
        return switch file.status {
        case .added: "added"
        case .deleted: "deleted"
        case .modified: "modified"
        case .renamed(let from): "renamed from \(from)"
        case .copied(let from): "copied from \(from)"
        }
    }
}

private struct DiffFileNotice: View {
    let file: ReviewedFile

    var body: some View {
        DiffNoticeText(message)
    }

    private var message: String {
        if let omission = file.omission {
            let size = ByteCountFormatter.string(fromByteCount: Int64(omission.patchBytes), countStyle: .file)
            return switch omission.reason {
            case .fileTooLarge: "This diff is too large to show (\(size))."
            case .responseBudget: "Not shown: the other files already fill this comparison (\(size))."
            }
        }
        if file.isBinary { return "Binary file not shown." }
        if file.isConflict { return "Unresolved conflict. Resolve it to see its changes." }
        if let mode = file.modeChange { return "File mode changed from \(mode.old) to \(mode.new)." }
        switch file.status {
        case .renamed(let from): return "Renamed from \(from) without changes."
        case .copied(let from): return "Copied from \(from) without changes."
        case .added: return "Empty file."
        case .deleted: return "Empty file deleted."
        case .modified: return "No content changes."
        }
    }
}

private struct DiffNoticeText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}

private struct DiffRowView: View, Equatable {
    let model: ChangeReviewModel
    let path: String
    let row: DiffRow
    let anchor: ReviewNote.Anchor?
    let gutterDigits: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.path == rhs.path && lhs.gutterDigits == rhs.gutterDigits && lhs.model === rhs.model
    }

    var body: some View {
        switch row.kind {
        case .gap(let hidden, let section):
            DiffGapRow(hiddenLines: hidden, section: section)
        case .line(let kind):
            VStack(alignment: .leading, spacing: 0) {
                DiffLineView(row: row, kind: kind, gutterDigits: gutterDigits)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let anchor { model.comment(on: anchor) }
                    }
                    .contextMenu {
                        if let anchor {
                            Button("Comment", systemImage: "text.bubble") { model.comment(on: anchor) }
                        }
                        Button("Copy Line", systemImage: "doc.on.doc") { HapticService.shared.copy(row.plain) }
                        if let anchor {
                            Button("Copy Location", systemImage: "link") { HapticService.shared.copy("\(path):\(anchor.line)") }
                        }
                    }
                    .accessibilityAction(named: "Comment") {
                        if let anchor { model.comment(on: anchor) }
                    }
                if let anchor, let draft = model.notes[anchor] {
                    ReviewNoteEditor(model: model, draft: draft)
                }
            }
        }
    }
}

private struct DiffGapRow: View {
    let hiddenLines: Int?
    let section: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .scaledFont(TypeMetrics.symbol(11, weight: .semibold))
            if let hiddenLines {
                Text(hiddenLines == 1 ? "1 unchanged line" : "\(hiddenLines) unchanged lines")
            }
            if !section.isEmpty {
                Text(section)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }
        }
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.06))
        .accessibilityElement(children: .combine)
    }
}

private struct DiffLineView: View {
    let row: DiffRow
    let kind: DiffLine.Kind
    let gutterDigits: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(String(repeating: "8", count: max(gutterDigits, 1))).hidden()
                Text((kind == .deletion ? row.oldNumber : row.newNumber).map(String.init) ?? "")
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 1)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DiffPalette.gutter(kind))

            Text(marker)
                .foregroundStyle(kind == .addition ? DiffPalette.added : kind == .deletion ? DiffPalette.removed : Color.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)

            if row.indent > 0 {
                Text(String(repeating: " ", count: row.indent))
                    .padding(.vertical, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text)
                    .fixedSize(horizontal: false, vertical: true)
                if row.hiddenCharacters > 0 {
                    Text("… \(row.hiddenCharacters) more characters")
                        .foregroundStyle(.secondary)
                }
                if row.lacksFinalNewline {
                    Text("No newline at end of file")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledFont(TypeMetrics.code)
        .fixedSize(horizontal: false, vertical: true)
        .background(DiffPalette.line(kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var marker: String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        }
    }

    private var accessibilityText: String {
        let line = (kind == .deletion ? row.oldNumber : row.newNumber).map { "line \($0), " } ?? ""
        return switch kind {
        case .addition: "\(line)added: \(row.plain)"
        case .deletion: "\(line)removed: \(row.plain)"
        case .context: "\(line)\(row.plain)"
        }
    }
}

struct ReviewNoteEditor: View {
    let model: ChangeReviewModel
    @Bindable var draft: ReviewNoteDraft
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Comment", text: $draft.text, axis: .vertical)
                .lineLimit(1...8)
                .focused($isFocused)
                .accessibilityIdentifier("change-review-note")
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(draft.anchor) }
                .labelStyle(.titleAndIcon)
                .scaledFont(.caption)
                .appButtonFeedback()
        }
        .scaledFont(.subheadline)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.4)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { isFocused = model.focusedNote == draft.anchor }
        .onChange(of: model.focusedNote) { _, focused in isFocused = focused == draft.anchor }
        .onChange(of: isFocused) { _, focused in
            if focused { model.focusedNote = draft.anchor } else if model.focusedNote == draft.anchor { model.focusedNote = nil }
        }
    }
}
