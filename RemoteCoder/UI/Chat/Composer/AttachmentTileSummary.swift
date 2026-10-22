import SwiftUI

struct AttachmentTileSummary<Status: View>: View {
    let symbol: String
    let title: String
    let maximumWidth: CGFloat
    let truncation: Text.TruncationMode
    @ViewBuilder let status: Status

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(truncation)
                status
                    .scaledFont(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 26)
        .frame(maxWidth: maximumWidth)
    }
}
