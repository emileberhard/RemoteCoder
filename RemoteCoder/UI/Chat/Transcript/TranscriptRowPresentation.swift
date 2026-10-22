import SwiftUI

@MainActor
final class TranscriptRowPresentation {
    enum Pin: Hashable { case mermaid(Int), htmlVisual(Int), htmlVisualExpansion(Int), questionFocus, questionConfirmation }

    private var store: TranscriptRowPresentations
    private let rowID: String
    private var loadedState: TranscriptRowPresentationState?
    private var pins: Set<Pin> = []
    var onPinChange: (Bool) -> Void = { _ in }

    init(store: TranscriptRowPresentations, rowID: String) {
        self.store = store
        self.rowID = rowID
    }

    func bind(to store: TranscriptRowPresentations) {
        guard self.store !== store else { return }
        self.store = store
        if let loadedState { self.loadedState = store.adopt(loadedState, for: rowID) }
    }

    private var state: TranscriptRowPresentationState {
        if let loadedState {
            let value = store.adopt(loadedState, for: rowID)
            self.loadedState = value
            return value
        }
        let value = store.state(for: rowID)
        loadedState = value
        return value
    }

    var timelineExpanded: Bool {
        get { state.timelineExpanded }
        set { state.timelineExpanded = newValue }
    }
    var mermaidSource: [Int: Bool] {
        get { state.mermaidSource }
        set { state.mermaidSource = newValue }
    }
    var questionExpandedFreeText: Set<Int> {
        get { state.questionExpandedFreeText }
        set { state.questionExpandedFreeText = newValue }
    }
    var questionExpandedOptions: Set<Int> {
        get { state.questionExpandedOptions }
        set { state.questionExpandedOptions = newValue }
    }
    var questionResendID: UUID? {
        get { state.questionResendID }
        set { state.questionResendID = newValue }
    }

    func setPinned(_ pinned: Bool, for owner: Pin) {
        let wasPinned = !pins.isEmpty
        if pinned { pins.insert(owner) } else { pins.remove(owner) }
        if wasPinned != !pins.isEmpty { onPinChange(!pins.isEmpty) }
    }

    func codeIsExpanded(_ index: Int, isStreaming: Bool) -> Bool { state.codeIsExpanded(index, isStreaming: isStreaming) }
    func setCodeExpanded(_ index: Int, expanded: Bool, isStreaming: Bool) {
        state.setCodeExpanded(index, expanded: expanded, isStreaming: isStreaming)
    }
    func synchronizeCode(_ index: Int, isStreaming: Bool) { state.synchronizeCode(index, isStreaming: isStreaming) }
    func retainBlocks(count: Int) { state.retainBlocks(count: count) }
}

extension EnvironmentValues {
    @Entry var transcriptRowPresentation: TranscriptRowPresentation?
    @Entry var transcriptBlockIndex: Int?
}
