import Foundation
import Observation

@MainActor
protocol PastedTextReferencing: AnyObject {
    var pastedText: PastedTextPromptBlock.Entry { get }
}

@MainActor
private final class PastedTextReference: NSObject, PastedTextReferencing {
    let pastedText: PastedTextPromptBlock.Entry
    init(_ entry: PastedTextPromptBlock.Entry) { pastedText = entry }
}

@MainActor
@Observable
final class ComposerDocument {
    enum Edit {
        case replace(NSRange, ComposerDocumentContent)
        case replaceAll(ComposerDocumentContent)
        case insert(ComposerDocumentContent)
        case append(ComposerDocumentContent)
        case prepend(ComposerDocumentContent)
        case dictation(String)
        case updatePaste(UUID, String)
    }

    struct Request {
        let id: UUID
        let edit: Edit
        let complete: (Result<Void, any Error>) -> Void
    }

    enum EditError: LocalizedError {
        case pendingLimit
        case changedRange
        var errorDescription: String? {
            switch self {
            case .pendingLimit: "Finish the current text input before adding more input."
            case .changedRange: "The selected text changed before the edit could be applied. Try the edit again."
            }
        }
    }

    private(set) var errorMessage: String?
    private(set) var isRetired = false
    static let pastedTextKey = NSAttributedString.Key("NSAttachment")
    let id = UUID()
    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        manager.runLoopModes = [.common]
        return manager
    }()
    private(set) var revision = 0
    @ObservationIgnored private(set) var buffer: NSMutableAttributedString
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    private struct MountedEditor {
        let perform: (Request) -> Void
        let isComposing: () -> Bool
        let retire: () -> Void
    }
    @ObservationIgnored private var editors: [UUID: MountedEditor] = [:]
    @ObservationIgnored private var pending: [(request: Request, revision: Int)] = []
    @ObservationIgnored private var lastComposing = false
    @ObservationIgnored private var activeEditor: UUID?
    @ObservationIgnored private var nonWhitespaceCount: Int
    @ObservationIgnored private var firstContentLocation: Int?
    @ObservationIgnored private let onChange: () -> Void

    init(content: ComposerDocumentContent, onChange: @escaping () -> Void) {
        buffer = Self.attributed(content)
        nonWhitespaceCount = Self.contentCount(buffer.string)
        firstContentLocation = Self.firstContent(in: buffer.string)
        self.onChange = onChange
    }

    var isEmpty: Bool { _ = revision; return buffer.length == 0 }
    var hasContent: Bool { _ = revision; return nonWhitespaceCount > 0 }
    var length: Int { _ = revision; return buffer.length }
    var isComposing: Bool { _ = revision; return editors.values.contains { $0.isComposing() } }

    var controlText: String {
        _ = revision
        guard hasContent else { return "" }
        guard let start = firstContentLocation else { return "" }
        let length = min(buffer.length - start, 128)
        var text = buffer.attributedSubstring(from: NSRange(location: start, length: length)).string
        if nonWhitespaceCount > Self.contentCount(text) { text += " …" }
        return text
    }

    var content: ComposerDocumentContent {
        _ = revision
        return content(in: NSRange(location: 0, length: buffer.length))
    }

    func content(in range: NSRange) -> ComposerDocumentContent {
        Self.content(in: buffer, range: range)
    }

    static func content(in buffer: NSAttributedString, range: NSRange) -> ComposerDocumentContent {
        var runs: [ComposerDocumentContent.Run] = []
        buffer.enumerateAttribute(pastedTextKey, in: range) { value, span, _ in
            if let entry = (value as? any PastedTextReferencing)?.pastedText {
                runs.append(.paste(entry))
            } else if span.length > 0 {
                runs.append(.text(buffer.attributedSubstring(from: span).string))
            }
        }
        return ComposerDocumentContent(runs: runs)
    }

    func mount(_ storage: NSMutableAttributedString, editor: @escaping (Request) -> Void, isComposing: @escaping () -> Bool, onRetire: @escaping () -> Void) -> UUID? {
        guard !isRetired else { onRetire(); return nil }
        precondition(editors.isEmpty || buffer === storage)
        buffer = storage
        let token = UUID()
        editors[token] = MountedEditor(perform: editor, isComposing: isComposing, retire: onRetire)
        if activeEditor == nil { activeEditor = token }
        return token
    }

    func activate(_ editor: UUID, selection: NSRange) {
        guard editors[editor] != nil else { return }
        activeEditor = editor
        self.selection = selection
    }

    func unmount(_ editor: UUID) {
        editors.removeValue(forKey: editor)
        if activeEditor == editor { activeEditor = editors.keys.first }
        if editors.isEmpty {
            buffer = Self.attributed(content)
            undoManager.removeAllActions()
        }
        editorStateChanged()
    }

    func edit(_ edit: Edit) {
        guard !isRetired else { errorMessage = ComposerDraftPersistence.Failure.retired.localizedDescription; return }
        perform(Request(id: UUID(), edit: edit) { [weak self] result in
            if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
            else { self?.errorMessage = nil }
        })
    }

    func restore(_ content: ComposerDocumentContent, then restored: @escaping (Bool) -> Void) {
        guard !isRetired else {
            errorMessage = ComposerDraftPersistence.Failure.retired.localizedDescription
            restored(false)
            return
        }
        perform(Request(id: UUID(), edit: .prepend(content)) { [weak self] result in
            switch result {
            case .success: self?.errorMessage = nil; restored(true)
            case .failure(let error): self?.errorMessage = error.localizedDescription; restored(false)
            }
        })
    }

    func apply(_ edit: Edit) async throws {
        try Task.checkCancellation()
        guard !isRetired else { throw ComposerDraftPersistence.Failure.retired }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                perform(Request(id: id, edit: edit, complete: { continuation.resume(with: $0) }))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = pending.firstIndex(where: { $0.request.id == id }) else { return }
                pending.remove(at: index).request.complete(.failure(CancellationError()))
            }
        }
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        for editor in Array(editors.values) { editor.retire() }
        buffer = Self.attributed(content)
        editors.removeAll()
        activeEditor = nil
        undoManager.removeAllActions()
        editorStateChanged()
    }

    private func perform(_ request: Request) {
        if isComposing {
            guard pending.count < 16 else { request.complete(.failure(EditError.pendingLimit)); return }
            pending.append((request, revision))
            return
        }
        if let activeEditor, let editor = editors[activeEditor] {
            editor.perform(request)
            return
        }
        guard let (range, replacement) = replacement(for: request.edit) else {
            request.complete(.success(()))
            return
        }
        let removed = buffer.attributedSubstring(from: range).string
        let inserted = Self.attributed(replacement)
        buffer.replaceCharacters(in: range, with: inserted)
        changedCharacters(in: range, removed: removed, inserted: inserted.string)
        selection = NSRange(location: range.location + inserted.length, length: 0)
        request.complete(.success(()))
    }

    func editorStateChanged() {
        let composing = isComposing
        guard composing != lastComposing || (!composing && !pending.isEmpty) else { return }
        lastComposing = composing
        revision += 1
        guard !composing else { return }
        let requests = pending
        pending.removeAll()
        for (request, expectedRevision) in requests {
            if case .replace = request.edit, expectedRevision + 1 != revision {
                request.complete(.failure(EditError.changedRange))
            } else { perform(request) }
        }
    }

    func replacement(for edit: Edit) -> (NSRange, ComposerDocumentContent)? {
        switch edit {
        case .replaceAll(let content):
            return (NSRange(location: 0, length: buffer.length), content)
        case .replace(let range, let content):
            precondition(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= buffer.length)
            return (range, content)
        case .insert(let content):
            return (selection, content)
        case .append(let content):
            return (NSRange(location: buffer.length, length: 0), content)
        case .prepend(let content):
            guard !content.runs.isEmpty else { return nil }
            return (NSRange(location: 0, length: 0), .init(runs: content.runs + (buffer.length == 0 ? [] : [.text("\n")])))
        case .dictation(let text):
            let before = selection.location > 0 ? buffer.attributedSubstring(from: NSRange(location: selection.location - 1, length: 1)).string : ""
            let after = NSMaxRange(selection) < buffer.length ? buffer.attributedSubstring(from: NSRange(location: NSMaxRange(selection), length: 1)).string : ""
            let insertion = (before.isEmpty || before.last?.isWhitespace == true ? "" : " ") + text
                + (after.isEmpty || after.first?.isWhitespace == true ? "" : " ")
            return (selection, .init(runs: [.text(insertion)]))
        case .updatePaste(let id, let text):
            var found: NSRange?
            buffer.enumerateAttribute(Self.pastedTextKey, in: NSRange(location: 0, length: buffer.length)) { value, range, stop in
                guard ((value as? any PastedTextReferencing)?.pastedText)?.id == id else { return }
                found = range
                stop.pointee = true
            }
            guard let found else { return nil }
            let runs: [ComposerDocumentContent.Run] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [.paste(.init(id: id, text: text))]
            return (found, .init(runs: runs))
        }
    }

    func changedCharacters(in range: NSRange, removed: String, inserted: String) {
        nonWhitespaceCount += Self.contentCount(inserted) - Self.contentCount(removed)
        updateFirstContent(in: range, inserted: inserted)
        selection.location = min(selection.location, buffer.length)
        selection.length = min(selection.length, buffer.length - selection.location)
        changed()
    }

    private func updateFirstContent(in range: NSRange, inserted: String) {
        if let first = firstContentLocation, first < range.location { return }
        let insertedLength = (inserted as NSString).length
        let insertedStart = Self.firstContent(in: inserted).map { $0 + range.location }
        if let first = firstContentLocation, first >= NSMaxRange(range) {
            firstContentLocation = min(first + insertedLength - range.length, insertedStart ?? .max)
        } else {
            firstContentLocation = insertedStart ?? Self.firstContent(in: buffer.string, after: range.location + insertedLength)
        }
    }

    func changedPasteAttributes() { changed() }

    private func changed() {
        revision += 1
        onChange()
    }

    static func attributed(_ content: ComposerDocumentContent) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in content.runs {
            switch run {
            case .text(let text): result.append(NSAttributedString(string: text))
            case .paste(let entry):
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: [pastedTextKey: PastedTextReference(entry)]))
            }
        }
        return result
    }

    private static func contentCount(_ text: String) -> Int {
        text.unicodeScalars.count(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func firstContent(in text: String, after start: Int = 0) -> Int? {
        let text = text as NSString
        let found = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, range: NSRange(location: start, length: text.length - start))
        return found.location == NSNotFound ? nil : found.location
    }
}
