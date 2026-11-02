#if DEBUG
import SwiftUI

private struct StatusPillsFixture: View {
    let changes: [ChangeTotals]
    @State private var theme = AppThemeStore()

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, totals in
                HStack(spacing: 8) {
                    ChangesPill(totals: totals, action: {})
                    StatusPill(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                            Text("1 subagent")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ThemedAppBackground() }
        .environment(theme)
    }
}

private let samples = [
    ChangeTotals(counted: [ChangeTotals.Lines(additions: 1, deletions: 0)], unlistedFiles: 0, isComplete: true),
    ChangeTotals(counted: Array(repeating: ChangeTotals.Lines(additions: 40, deletions: 5), count: 12), unlistedFiles: 0, isComplete: true),
    ChangeTotals(counted: Array(repeating: ChangeTotals.Lines(additions: 900, deletions: 412), count: 40), unlistedFiles: 0, isComplete: true),
    ChangeTotals(counted: [ChangeTotals.Lines(additions: 3, deletions: 1)], unlistedFiles: 2, isComplete: true),
]

#Preview("Dark") {
    StatusPillsFixture(changes: samples)
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    StatusPillsFixture(changes: samples)
        .preferredColorScheme(.light)
}
#endif
