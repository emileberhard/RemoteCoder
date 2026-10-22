import SwiftUI

struct CompletionBanner: View {
    let notification: ForegroundNotificationPresentation.Banner
    let onTap: () -> Void

    private static let cornerRadius: CGFloat = 24

    private var symbol: String {
        if notification.payload?.questionItemID != nil { return "questionmark.circle.fill" }
        switch notification.payload?.outcome {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.circle.fill"
        case nil: return "bell.fill"
        }
    }

    private var tint: Color {
        if notification.payload?.questionItemID != nil { return .orange }
        switch notification.payload?.outcome {
        case .success: return .green
        case .failure: return .red
        case nil: return .secondary
        }
    }

    var body: some View {
        Group {
            if notification.payload?.sessionID != nil {
                Button(action: onTap) { content }
                    .buttonStyle(ResponsiveButtonStyle())
            } else {
                content
            }
        }
        .appGlass(.standard, in: .rect(cornerRadius: Self.cornerRadius))
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .scaledFont(TypeMetrics.symbol(18, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.delivery.title)
                    .scaledFont(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(notification.delivery.body)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            if notification.payload?.sessionID != nil {
                Image(systemName: "chevron.right")
                    .scaledFont(TypeMetrics.symbol(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassTapTarget(cornerRadius: Self.cornerRadius)
    }
}
