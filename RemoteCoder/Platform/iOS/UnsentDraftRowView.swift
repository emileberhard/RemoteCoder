import SwiftUI

struct UnsentDraftRowView: View, Equatable {
    let row: UnsentDraftRow
    let open: () -> Void
    let discard: () -> Void
    @Environment(AppThemeStore.self) private var themeStore
    @ScaledMetric(relativeTo: .caption2) private var markSize: CGFloat = 13

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if row.showsHostLabel {
                        Text(row.hostName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(themeStore.theme.colors.accentTint)
                            .lineLimit(1)
                            .accessibilityLabel("On \(row.hostName)")
                        if !row.workingDirectory.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(row.workingDirectory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if let provider = row.provider {
                        Image(provider.markImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: markSize, height: markSize)
                            .foregroundStyle(provider.markStyle)
                            .accessibilityLabel("\(provider.displayName) draft")
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.subheadline)
                        .fontWeight(row.isSelected ? .semibold : .medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let ageLabel = row.ageLabel, let modifiedAt = row.modifiedAt {
                        Text(ageLabel)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel(Text(.currentDate, format: .reference(to: modifiedAt)))
                    }
                }
            }
            .contentTransition(.identity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassTapTarget(cornerRadius: 16)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: row.isSelected ? .buttonPress : nil, pressedScale: 0.985, pressedOpacity: 0.94))
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        .accessibilityActions {
            Button("Discard Draft", systemImage: "trash", action: discard)
        }
        .appContentSurface(row.isSelected ? .selected : .standard, in: .rect(cornerRadius: 16))
    }
}
