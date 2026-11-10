#if DEBUG
import SwiftUI

private struct ImmediateClock: Clock {
    var now: ContinuousClock.Instant { .now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {}
}

private enum SearchFixture {
    static let mini = UUID(uuidString: "6F1C2A4E-0D7B-4C1E-9B55-1E7F0C9A2B31") ?? UUID()
    static let linux = UUID(uuidString: "2B8E5D10-7A3C-4F6B-8E21-4C9D7B0A5E62") ?? UUID()
    static let macBook = UUID(uuidString: "9A4F7C23-5B1E-4D8A-A6C3-7E2B9D1F0C84") ?? UUID()

    static func hosts(rows: Int, linuxAnswers: Bool) -> [ConversationSearchHost] {
        [
            host(mini, "Mini", answer: .results(response(on: mini, rows: rows))),
            linuxAnswers
                ? host(linux, "Linux", answer: nil)
                : ConversationSearchHost(id: linux, name: "Linux", gatewayID: nil, headers: [], marks: marks, availability: .unreachable),
            host(macBook, "MacBook", answer: linuxAnswers ? .results(.init(schemaVersion: 1, conversations: [])) : .unsupported),
        ]
    }

    private static let marks = ConversationMarks(schemaVersion: 5, revision: 1, readBaseline: 0, threads: [:])

    private static func host(_ id: UUID, _ name: String, answer: ConversationSearchHost.Answer?) -> ConversationSearchHost {
        ConversationSearchHost(id: id, name: name, gatewayID: nil, headers: [], marks: marks, availability: .connected { _ in
            guard let answer else {
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            }
            return answer
        })
    }

    private static func response(on host: UUID, rows: Int) -> ConversationSearchResponse {
        let now = Date.now
        func conversation(_ thread: String, _ provider: AgentProvider, title: String?, cwd: String, hoursAgo: Double,
                          titleMatch: Bool, hitCount: Int, excerpt: String?) -> ConversationSearchResponse.Conversation {
            ConversationSearchResponse.Conversation(
                sessionKey: "\(host.uuidString):\(provider.rawValue):\(thread)", hostId: host, provider: provider,
                threadId: thread, title: title, cwd: cwd, lastAt: now.addingTimeInterval(-hoursAgo * 3_600),
                titleMatch: titleMatch, hitCount: hitCount, hits: excerpt.map { [.init(excerpt: $0)] } ?? [])
        }
        return ConversationSearchResponse(schemaVersion: 1, conversations: Array([
            conversation("t1", .codex, title: "Drawer flicker on open", cwd: "/Users/emil/RemoteCoder", hoursAgo: 2,
                         titleMatch: true, hitCount: 6,
                         excerpt: "Opening the history panel twice in a row reproduces it every time: the drawer flicker shows up when the list reloads under the finger while it slides open."),
            conversation("claude_t2", .claude, title: "Fix drawer flicker after a host switch", cwd: "/Users/emil/RemoteCoder-worktrees/drawer-fix",
                         hoursAgo: 20, titleMatch: true, hitCount: 0, excerpt: nil),
            conversation("t3", .codex, title: "Drawer flicker with Reduce Motion", cwd: "/Users/emil/RemoteCoder", hoursAgo: 50,
                         titleMatch: true, hitCount: 1,
                         excerpt: "With Reduce Motion on the drawer still crossfades, so the flicker is the opacity transition rather than the layout."),
            conversation("t4", .codex, title: "Flicker in the drawer's glass", cwd: "/Users/emil/RemoteCoder", hoursAgo: 120,
                         titleMatch: true, hitCount: 2, excerpt: "The glass flicker in the drawer comes from the backdrop re-sampling while the keyboard animates."),
            conversation("claude_t5", .claude, title: "Drawer flicker regression in 4.9", cwd: "/Users/emil/RemoteCoder", hoursAgo: 400,
                         titleMatch: true, hitCount: 1, excerpt: "Bisected the drawer flicker to the snapshot change in 4.9.2."),
            conversation("t6", .codex, title: "Mac sidebar virtualization", cwd: "/Users/emil/RemoteCoder", hoursAgo: 26,
                         titleMatch: false, hitCount: 3,
                         excerpt: "Measured the sidebar again after the estimate change: no flicker at all now, but the drawer still drops one frame when the first row mounts on the old iPhone."),
            conversation("claude_t7", .claude, title: "Transcript scroll hitches", cwd: "/Users/emil/stretch/amni-care", hoursAgo: 75,
                         titleMatch: false, hitCount: 2,
                         excerpt: "The flicker turned out to be the drawer's shadow re-rendering every frame; caching the path fixed it."),
            conversation("t8", .codex, title: nil, cwd: "/Users/emil", hoursAgo: 160, titleMatch: false, hitCount: 1,
                         excerpt: "drawer flicker reproduced on the iPad with Stage Manager, never on the iPhone"),
            conversation("t9", .codex, title: "Liquid Glass audit", cwd: "/Users/emil/RemoteCoder", hoursAgo: 700, titleMatch: false,
                         hitCount: 4, excerpt: "Every glass surface in the drawer passes except the search capsule, which flickers when the keyboard appears."),
        ].prefix(rows)))
    }
}

private struct ConversationSearchFixture: View {
    @State private var theme = AppThemeStore()
    @State private var search: ConversationSearchSession

    init(query: String, rows: Int, linuxAnswers: Bool) {
        let hosts = SearchFixture.hosts(rows: rows, linuxAnswers: linuxAnswers)
        let session = ConversationSearchSession(clock: ImmediateClock()) { hosts }
        session.query = query
        _search = State(initialValue: session)
    }

    var body: some View {
        #if os(iOS)
        ZStack {
            ThemedSheetBackground()
            ConversationSearchList(search: search, open: { _ in .changed })
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    DrawerSearchField(search: search)
                }
        }
        .environment(theme)
        #else
        ConversationSearchList(search: search, open: { _ in .changed })
            .frame(width: 300, height: 760)
            .environment(theme)
        #endif
    }
}

#Preview("Results") {
    ConversationSearchFixture(query: "drawer flicker", rows: 9, linuxAnswers: false)
}

#Preview("Unavailable hosts") {
    ConversationSearchFixture(query: "drawer flicker", rows: 2, linuxAnswers: false)
}

#Preview("Searching") {
    ConversationSearchFixture(query: "drawer flicker", rows: 2, linuxAnswers: true)
}
#endif
