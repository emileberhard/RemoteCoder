#if DEBUG
import SwiftUI

private struct StatusPillsFixture: View {
    let pills: [ChangesPillContent]
    @State private var theme = AppThemeStore()
    @State private var changes = ChangeReviewFixture.client().map {
        ChangeReviewFixture.summaryModel(view: .standard, summary: nil, client: $0)
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(pills.enumerated()), id: \.offset) { _, content in
                HStack(spacing: 8) {
                    if let changes {
                        ChangesPill(changes: changes, content: content, action: {})
                    }
                    StatusPill(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                            Text("4 subagents")
                            Image(systemName: "ellipsis")
                        }
                    }
                    .layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ThemedAppBackground() }
        .environment(theme)
    }
}

private let samples = [
    ChangesPillContent(view: .standard, count: .known(ChangeTotals(counted: [ChangeTotals.Lines(additions: 1, deletions: 0)],
                                                             unlistedFiles: 0, isComplete: true))),
    ChangesPillContent(view: .standard, count: .known(ChangeTotals(counted: Array(repeating: ChangeTotals.Lines(additions: 40, deletions: 5), count: 12),
                                                             unlistedFiles: 0, isComplete: true))),
    ChangesPillContent(view: .lastTurn, count: .known(ChangeTotals(counted: Array(repeating: ChangeTotals.Lines(additions: 900, deletions: 412), count: 40),
                                                             unlistedFiles: 0, isComplete: true))),
    ChangesPillContent(view: .lastTurn, count: .unknown),
    ChangesPillContent(view: .since(ChangesAnchor(turnID: "turn-2", boundary: .end)),
                       since: TurnChanges.Since(anchor: ChangesAnchor(turnID: "turn-2", boundary: .end),
                                                atMs: Int64(Date.now.timeIntervalSince1970 * 1_000), turns: 0),
                       count: .known(ChangeTotals(counted: [ChangeTotals.Lines?](), unlistedFiles: 0, isComplete: true))),
    ChangesPillContent(view: .git(.unstaged), count: .known(ChangeTotals(counted: [ChangeTotals.Lines(additions: 3, deletions: 1)],
                                                                   unlistedFiles: 2, isComplete: true))),
    ChangesPillContent(view: .since(ChangesAnchor(turnID: "gone", boundary: .end)), count: .startMissing),
]

#Preview("Dark") {
    StatusPillsFixture(pills: samples)
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    StatusPillsFixture(pills: samples)
        .preferredColorScheme(.light)
}
#endif
