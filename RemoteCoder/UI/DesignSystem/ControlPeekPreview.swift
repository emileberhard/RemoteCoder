import SwiftUI

struct ControlPeekPreview: View {
    let symbol: String
    let title: String
    let subtitle: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).scaledFont(.headline).lineLimit(3)
            Text(subtitle).scaledFont(.caption).foregroundStyle(.secondary)
            if !detail.isEmpty { Text(detail).scaledFont(.callout).lineLimit(10) }
        }
        .frame(width: 280, alignment: .leading)
        .padding(20)
    }
}
