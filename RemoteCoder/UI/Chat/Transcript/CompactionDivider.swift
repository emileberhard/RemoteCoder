import SwiftUI

struct CompactionDivider: View {
    let marker: CompactionMarker
    let visibility: TranscriptVisibility
    let refresh: (() -> Void)?
    @InterfaceScaledMetric(relativeTo: .caption) private var labelHeight = 20.0
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible

    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif

    var body: some View {
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                line
                HStack(spacing: 6) {
                    if marker.compaction.isActive {
                        if energyPolicy.animatesDecorations(sceneActive: scenePhase == .active,
                            visible: visualsVisible && visibility.shows(rowID: marker.id), reduceMotion: reduceMotion) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                        } else {
                            Image(systemName: "ellipsis").accessibilityHidden(true)
                        }
                    }
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                .layoutPriority(1)
                .frame(minHeight: labelHeight)
                line
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            if let detail {
                Text(detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if marker.compaction.blocksSending, let refresh {
                Button("Refresh status", systemImage: "arrow.clockwise", action: refresh)
                    .buttonStyle(ResponsiveButtonStyle())
                    .frame(minHeight: ControlMetrics.minimumTarget * interfaceScale)
                    .accessibilityIdentifier("transcript-compaction-refresh")
            }
        }
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.vertical, 12)
        .accessibilityIdentifier("transcript-\(marker.id)")
    }

    private var line: some View {
        Rectangle()
            .fill(.secondary.opacity(0.3))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var title: String {
        switch marker.compaction.phase {
        case .requesting, .running: "Compacting context…"
        case .completed: "Context compacted"
        case .interrupted: "Compaction stopped"
        case .failed: "Couldn’t compact context"
        case .unconfirmed: "Compaction status unavailable"
        }
    }

    private var detail: String? {
        switch marker.compaction.phase {
        case .failed(let message): message
        case .unconfirmed: marker.compaction.blocksSending
            ? "Refresh to check the result before continuing."
            : "Compaction could not be confirmed."
        default: nil
        }
    }
}
