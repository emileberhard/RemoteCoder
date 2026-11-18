import SwiftUI

struct HostAvailabilityStrip: View {
    let lines: [HostPresentation.Line]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.text) { line in
                    Label(line.text, systemImage: "network.slash")
                        .scaledFont(.caption)
                        .foregroundStyle(line.tone == .warning ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
