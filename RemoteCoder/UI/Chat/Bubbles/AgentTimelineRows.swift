import SwiftUI

struct AgentTimelineHeader: View {
    let timeline: JobTimeline
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif

    var body: some View {
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        Button {
            onToggle()
        } label: {
            HStack(spacing: 5) {
                collapsedLabel
                DisclosureChevron(isExpanded: timeline.isExpanded)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 0.99))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(timeline.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(timeline.isExpanded ? "Hides timeline details" : "Shows timeline details")
        .padding(.vertical, timeline.isExpanded ? 4 : 0)
        .animation(reduceMotion ? nil : .smooth, value: timeline.isExpanded)
    }

    @ViewBuilder
    private var collapsedLabel: some View {
        if timeline.isLive {
            ThinkingStatusLabel()
        } else {
            Text(summaryText)
                .scaledFont(.callout)
        }
    }

    private var summaryText: String {
        // Only a span bounded by real observations is worth showing. Anything else
        // would be a guess dressed up as a measurement, so fall back to the count.
        if let duration = JobTimelineSpan.displayDuration(
            startedAt: timeline.startedAt,
            completedAt: timeline.completedAt
        ) {
            return "Thought for \(formatDuration(duration))"
        }
        let count = timeline.events.count
        if count == 0 { return "Thinking" }
        return count == 1 ? "Thought through 1 action" : "Thought through \(count) actions"
    }

    private var accessibilityLabel: String {
        timeline.isLive ? "Thinking" : summaryText
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

private struct ThinkingStatusLabel: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.transcriptRowVisibility) private var rowVisibility

    var body: some View {
        HStack(spacing: 1) {
            Text("Thinking")
            ThinkingDots(tint: .secondary, isAnimating: energyPolicy.animatesDecorations(
                sceneActive: scenePhase == .active, visible: rowVisibility?.isVisible == true && visualsVisible,
                reduceMotion: reduceMotion))
        }
        .scaledFont(.callout)
    }
}

struct TimelineEventRow: View {
    let event: JobTimelineEvent
    let isLast: Bool
    @State private var localIsExpanded = false
    @Environment(\.transcriptRowPresentation) private var rowPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool {
        get { rowPresentation?.timelineExpanded ?? localIsExpanded }
        nonmutating set {
            if let rowPresentation { rowPresentation.timelineExpanded = newValue }
            else { localIsExpanded = newValue }
        }
    }

    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif

    var body: some View {
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        VStack(alignment: .leading, spacing: 8) {
            if canExpand {
                Button(action: toggle) {
                    summary
                }
                .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 1, pressedOpacity: 0.6))
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides details" : "Shows details")

                if isExpanded, event.details.isEmpty == false {
                    TimelineEventDetails(
                        details: event.details,
                        timestamp: event.timestamp,
                        isProse: event.kind.isNarrative
                    )
                    .transition(.opacity)
                }
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, TimelineMarker.columnWidth)
        .background(alignment: .topLeading) {
            TimelineMarker(isFailure: event.kind.isFailure, isLast: isLast)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.title)
                    .scaledFont(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if canExpand {
                    DisclosureChevron(isExpanded: isExpanded)
                        .foregroundStyle(.tertiary)
                }
            }

            if let subtitle = event.subtitle, subtitle.isEmpty == false {
                Text(subtitle)
                    .scaledFont(.caption)
                    .lineLimit(canExpand && isExpanded == false ? 2 : nil)
                    .truncationMode(event.kind.isNarrative ? .tail : .middle)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var canExpand: Bool {
        event.details.isEmpty == false || (event.subtitle?.utf8.count ?? 0) > Self.fullSubtitleLength
    }

    private static let fullSubtitleLength = 200

    private func toggle() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            isExpanded.toggle()
        }
    }
}

private struct TimelineEventDetails: View {
    let details: [JobTimelineEventDetail]
    let timestamp: Date?
    let isProse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(details) { detail in
                VStack(alignment: .leading, spacing: 2) {
                    if details.count > 1 {
                        Text(detail.label.replacing("_", with: " "))
                            .foregroundStyle(.secondary)
                    }
                    Text(detail.value)
                        .fontDesign(isProse ? .default : .monospaced)
                        .foregroundStyle(.primary)
                        .transcriptPerfFeature("textSelection") { $0.textSelection(.enabled) }
                }
            }
            if let timestamp {
                Text(timestamp, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .scaledFont(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

private struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .scaledFont(.caption2.weight(.semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

private struct TimelineMarker: View {
    static let columnWidth: CGFloat = 16

    let isFailure: Bool
    let isLast: Bool
    @InterfaceScaledMetric(relativeTo: .caption) private var markerInset: CGFloat = 3
    @InterfaceScaledMetric(relativeTo: .caption) private var markerSize: CGFloat = 9
    @InterfaceScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 5
    @Environment(AppThemeStore.self) private var themeStore

    private static let connectorGap: CGFloat = 1

    var body: some View {
        VStack(spacing: Self.connectorGap) {
            marker
                .frame(width: markerSize, height: markerSize)
                .padding(.top, markerInset)
            if isLast == false {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, Self.connectorGap)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, isLast ? 0 : -(TranscriptLayout.spacing + markerInset))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var marker: some View {
        if isFailure {
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .foregroundStyle(themeStore.theme.colors.danger)
        } else {
            Circle()
                .fill(.tertiary)
                .frame(width: dotSize, height: dotSize)
        }
    }
}

private extension JobTimelineEventKind {
    var isFailure: Bool { self == .toolError || self == .error }
    var isNarrative: Bool { self == .progress || self == .message }
}
