import SwiftUI

@MainActor
@Observable
final class TranscriptFind {
    enum Direction { case next, previous }

    private(set) var isPresented = false
    var query = ""
    private(set) var matches: [String] = []
    private(set) var currentIndex: Int?
    private(set) var focusRequest = 0

    var hasMatches: Bool { !matches.isEmpty }

    func present() {
        isPresented = true
        focusRequest += 1
    }

    func dismiss() {
        isPresented = false
        query = ""
        matches = []
        currentIndex = nil
    }

    func show(_ matches: [String], in screen: ChatScreenModel) {
        self.matches = matches
        currentIndex = matches.indices.last
        revealCurrentMatch(in: screen)
    }

    func move(_ direction: Direction, in screen: ChatScreenModel) {
        guard let currentIndex else { return }
        let step = direction == .next ? 1 : -1
        self.currentIndex = (currentIndex + step + matches.count) % matches.count
        revealCurrentMatch(in: screen)
    }

    private func revealCurrentMatch(in screen: ChatScreenModel) {
        if let currentIndex { screen.revealTranscriptRow(matches[currentIndex]) }
    }

    @concurrent
    nonisolated static func matches(for query: String, in items: [ChatStreamItem]) async -> [String] {
        TranscriptSearch.matchingRowIDs(query, in: items)
    }
}

struct TranscriptFindBar: View {
    @Bindable var find: TranscriptFind
    let screen: ChatScreenModel
    @FocusState private var isFieldFocused: Bool

    private struct SearchKey: Equatable {
        let query: String
        let screen: ObjectIdentifier
        let transcript: String
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in Conversation", text: $find.query)
                .textFieldStyle(.plain)
                #if os(macOS)
                .frame(maxWidth: .infinity)
                #else
                .frame(width: 200)
                #endif
                .focused($isFieldFocused)
                .onSubmit { find.move(.next, in: screen) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.move(.previous, in: screen)
                    return .handled
                }
                .onKeyPress(.escape) {
                    find.dismiss()
                    return .handled
                }
            if !find.query.isEmpty {
                Text(matchStatus)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Previous Match", systemImage: "chevron.up") { find.move(.previous, in: screen) }
                .tooltip("Show the previous match")
                .disabled(!find.hasMatches)
            Button("Next Match", systemImage: "chevron.down") { find.move(.next, in: screen) }
                .tooltip("Show the next match")
                .disabled(!find.hasMatches)
            Button("Close Find", systemImage: "xmark.circle.fill") { find.dismiss() }
                .tooltip("Close find")
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        #if os(macOS)
        .frame(maxWidth: .infinity)
        .background(.bar, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
        #else
        .appGlass(.standard, in: .capsule)
        #endif
        .onChange(of: find.focusRequest, initial: true) { isFieldFocused = true }
        .task(id: SearchKey(query: find.query, screen: ObjectIdentifier(screen), transcript: screen.transcriptIdentity)) {
            let query = find.query
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            let matches = await TranscriptFind.matches(for: query, in: screen.streamItems)
            guard !Task.isCancelled else { return }
            find.show(matches, in: screen)
        }
    }

    private var matchStatus: String {
        guard let currentIndex = find.currentIndex else { return "No matches" }
        return "\(currentIndex + 1) of \(find.matches.count)"
    }
}
