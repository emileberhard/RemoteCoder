import SwiftUI

struct ClusterCoverageStrip: View {
    let coverage: [ClusterCoverage]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(coverage) { member in
                    Label {
                        HStack(spacing: 4) {
                            Text(member.name ?? member.hostId.uuidString)
                            Text(status(member))
                        }
                    } icon: {
                        Image(systemName: symbol(member.state))
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(member.state == .ok ? Color.secondary : Color.orange)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func status(_ member: ClusterCoverage) -> String {
        switch member.state {
        case .ok: "OK"
        case .unreachable: member.since.map { "Unreachable since \($0)" } ?? "Unreachable"
        case .unsupported: "Too old"
        case .stale: member.staleThrough.map { "Stale through \($0)" } ?? "Stale"
        case .unknown: "Unknown"
        case .removed: "Removed"
        case .refused: "Refused"
        }
    }

    private func symbol(_ state: ClusterCoverage.State) -> String {
        switch state {
        case .ok: "checkmark.circle"
        case .unreachable: "network.slash"
        case .unsupported, .stale: "clock.badge.exclamationmark"
        case .unknown: "questionmark.circle"
        case .removed, .refused: "minus.circle"
        }
    }
}
