#if DEBUG
import SwiftUI

private enum SearchFixture {
    static let mini = UUID(uuidString: "6F1C2A4E-0D7B-4C1E-9B55-1E7F0C9A2B31") ?? UUID()

    static func results(status: ConversationSearchStatus, byMeaning: Bool) -> ConversationSearchResults {
        var results = ConversationSearchResults(status: status, isPainted: true)
        results.titles.append(row("t1", .titles, "Drawer flicker on open", provider: .codex,
                                  date: "14:18", excerpt: "The drawer flickers when the list reloads under the finger while it slides open."))
        results.titles.append(row("claude_t2", .titles, "Fix drawer flicker after a host switch", provider: .claude, date: "Yesterday"))
        results.messages.append(row("t3", .messages, "Mac sidebar virtualization", provider: .codex,
                                    date: "10 Nov", excerpt: "The drawer still drops one frame when the first row mounts on the old iPhone."))
        if byMeaning {
            results.meaning.append(row("claude_meaning", .meaning, "Improve sidebar opening", provider: .claude,
                                       excerpt: "The sidebar stuttered when it revealed freshly measured rows. A cached layout kept the motion smooth."))
        }
        return results
    }

    private static func row(_ thread: String, _ section: ConversationSearchSection.Kind, _ title: String,
                            provider: AgentProvider, date: String? = nil, excerpt: String? = nil) -> ConversationSearchRow {
        ConversationSearchRow(address: ConversationAddress(hostID: mini, threadID: thread), section: section,
                              itemKey: section == .messages ? "fixture@item:1" : nil,
                              findTerm: section == .messages ? "drawer" : nil,
                              sessionKey: nil, generation: 1, headline: .title(title),
                              excerpt: excerpt.map { AttributedString($0) }, dateLabel: date, provider: provider,
                              folder: "RemoteCoder", hostName: "Mini", additionalHitCount: section == .messages ? 2 : 0)
    }
}

private struct ConversationSearchFixture: View {
    @State private var theme = AppThemeStore()
    @State private var search: ConversationSearchSession

    init(_ results: ConversationSearchResults) {
        _search = State(initialValue: ConversationSearchSession(previewQuery: "drawer flicker", results: results))
    }

    var body: some View {
        #if os(iOS)
        ZStack {
            ThemedSheetBackground()
            ConversationSearchList(search: search, open: { _ in .changed }, ask: {})
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    DrawerSearchField(search: search)
                }
        }
        .environment(theme)
        #else
        ConversationSearchList(search: search, open: { _ in .changed }, ask: {})
            .frame(width: 300, height: 760)
            .environment(theme)
        #endif
    }
}

#Preview("Results") {
    ConversationSearchFixture(SearchFixture.results(status: .init(), byMeaning: false))
}

#Preview("Unavailable hosts") {
    ConversationSearchFixture(SearchFixture.results(status: .init(unansweredHosts: ["Linux"], unsupportedHosts: ["MacBook"]), byMeaning: false))
}

#Preview("Searching") {
    ConversationSearchFixture(SearchFixture.results(status: .init(isSearching: true), byMeaning: true))
}

#Preview("By meaning and Ask") {
    ConversationSearchFixture(SearchFixture.results(status: .init(), byMeaning: true))
}

#Preview("Located message") {
    ZStack {
        ThemedSheetBackground()
        VStack(alignment: .leading, spacing: 20) {
            Text("What caused the drawer to stutter?")
                .scaledFont(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("The **drawer** measured the first row during its opening animation. Reusing the cached height removed the hitch.")
                .scaledFont(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(TranscriptSearchHighlight(isHighlighted: true))
        }
        .padding(16)
    }
    .environment(AppThemeStore())
}
#Preview("Incomplete empty") {
    ConversationSearchFixture(.init(status: .init(partialHosts: ["Mini"]), isPainted: true))
}

#Preview("Incomplete results") {
    ConversationSearchFixture(SearchFixture.results(status: .init(partialHosts: ["Mini"]), byMeaning: false))
}

#Preview("Incomplete and unavailable") {
    ConversationSearchFixture(SearchFixture.results(
        status: .init(unansweredHosts: ["Linux"], unsupportedHosts: ["MacBook"], partialHosts: ["Mini"]), byMeaning: false))
}
#endif
