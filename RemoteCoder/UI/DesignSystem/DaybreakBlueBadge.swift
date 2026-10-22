import SwiftUI

struct DaybreakBlueBadge: View {
    var body: some View {
        Text("Daybreak Blue")
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.blue.opacity(0.1), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Daybreak Blue enabled automatically")
    }
}
