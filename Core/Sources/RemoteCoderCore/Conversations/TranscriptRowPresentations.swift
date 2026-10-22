import Foundation
import Observation

struct TranscriptPresentationRows: Sendable {
    let identity = UUID()
    let rowIDs: Set<String>
}

@MainActor
@Observable
final class TranscriptRowPresentationState {
    private struct CodeExpansion: Equatable {
        let isStreaming: Bool
        let expanded: Bool
    }

    @ObservationIgnored private weak var readingPosition: TranscriptReadingPosition?
    private var expandedTimeline = false
    private var codeExpansion: [Int: CodeExpansion] = [:]
    private var diagramSources: [Int: Bool] = [:]
    private var expandedFreeText: Set<Int> = []
    private var expandedOptions: Set<Int> = []
    private var resendID: UUID?

    init(readingPosition: TranscriptReadingPosition?) {
        self.readingPosition = readingPosition
    }

    func bindReadingPosition(_ position: TranscriptReadingPosition) { readingPosition = position }

    var timelineExpanded: Bool {
        get { expandedTimeline }
        set {
            guard expandedTimeline != newValue else { return }
            readingPosition?.preparePresentationChange()
            expandedTimeline = newValue
        }
    }

    var mermaidSource: [Int: Bool] {
        get { diagramSources }
        set {
            guard diagramSources != newValue else { return }
            readingPosition?.preparePresentationChange()
            diagramSources = newValue
        }
    }

    var questionExpandedFreeText: Set<Int> {
        get { expandedFreeText }
        set {
            guard expandedFreeText != newValue else { return }
            readingPosition?.preparePresentationChange()
            expandedFreeText = newValue
        }
    }

    var questionExpandedOptions: Set<Int> {
        get { expandedOptions }
        set {
            guard expandedOptions != newValue else { return }
            readingPosition?.preparePresentationChange()
            expandedOptions = newValue
        }
    }

    var questionResendID: UUID? {
        get { resendID }
        set {
            guard resendID != newValue else { return }
            readingPosition?.preparePresentationChange()
            resendID = newValue
        }
    }

    func codeIsExpanded(_ index: Int, isStreaming: Bool) -> Bool {
        guard let state = codeExpansion[index], state.isStreaming == isStreaming else { return false }
        return !isStreaming && state.expanded
    }

    func setCodeExpanded(_ index: Int, expanded: Bool, isStreaming: Bool) {
        let next = CodeExpansion(isStreaming: isStreaming, expanded: !isStreaming && expanded)
        guard codeExpansion[index] != next else { return }
        readingPosition?.preparePresentationChange()
        codeExpansion[index] = next
    }

    func synchronizeCode(_ index: Int, isStreaming: Bool) {
        if codeExpansion[index]?.isStreaming != isStreaming {
            setCodeExpanded(index, expanded: false, isStreaming: isStreaming)
        }
    }

    func retainBlocks(count: Int) {
        let codes = codeExpansion.filter { $0.key < count }
        let diagrams = diagramSources.filter { $0.key < count }
        guard codes.count != codeExpansion.count || diagrams.count != diagramSources.count else { return }
        readingPosition?.preparePresentationChange()
        codeExpansion = codes
        diagramSources = diagrams
    }
}

@MainActor
final class TranscriptRowPresentations {
    private var entries: [String: TranscriptRowPresentationState] = [:]
    private weak var readingPosition: TranscriptReadingPosition?
    private var sourceRevision: UInt64?
    private var sourceRowIDs: Set<String> = []
    private var membershipID: UUID?

    nonisolated init() {}

    var count: Int { entries.count }
    var sourceIdentity: UUID? { membershipID }

    func sourceContains(_ rowID: String) -> Bool? {
        membershipID.map { _ in sourceRowIDs.contains(rowID) }
    }

    func state(for rowID: String) -> TranscriptRowPresentationState {
        if let existing = entries[rowID] { return existing }
        let state = TranscriptRowPresentationState(readingPosition: readingPosition)
        if sourceRowIDs.contains(rowID) { entries[rowID] = state }
        return state
    }

    func prepareSource(_ snapshot: ConversationSnapshot, readingPosition: TranscriptReadingPosition) {
        guard sourceRevision.map({ snapshot.revision > $0 }) ?? true else { return }
        self.readingPosition = readingPosition
        readingPosition.prepareSource(revision: snapshot.revision)
        if membershipID != snapshot.presentationRows.identity {
            sourceRowIDs = snapshot.presentationRows.rowIDs
            entries = entries.filter { sourceRowIDs.contains($0.key) }
            membershipID = snapshot.presentationRows.identity
        }
        sourceRevision = snapshot.revision
    }

    func adopt(_ state: TranscriptRowPresentationState, for rowID: String) -> TranscriptRowPresentationState {
        if let existing = entries[rowID] { return existing }
        if let readingPosition { state.bindReadingPosition(readingPosition) }
        if sourceRowIDs.contains(rowID) { entries[rowID] = state }
        return state
    }

    func adopt(_ previous: TranscriptRowPresentations, readingPosition: TranscriptReadingPosition) {
        guard previous !== self else { return }
        self.readingPosition = readingPosition
        for (id, state) in previous.entries where sourceRowIDs.contains(id) && entries[id] == nil {
            state.bindReadingPosition(readingPosition)
            entries[id] = state
        }
        previous.entries.removeAll()
    }
}
