import ActivityKit
import SwiftUI
import WidgetKit

private typealias ContentState = RemoteCoderActiveTasksAttributes.ContentState
private typealias Attention = ContentState.Attention

struct LiveActivityGlyph: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image("LiveActivityAppGlyph")
            .resizable()
            .renderingMode(.original)
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct RunningIndicator: View {
    let count: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tint.opacity(0.25), lineWidth: size / 11)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.tint, style: StrokeStyle(lineWidth: size / 11, lineCap: .round))
                .rotationEffect(.degrees(Double(count) * 120 - 90))
            Text("\(count)")
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.8), value: count)
        .accessibilityElement()
        .accessibilityLabel("\(count) running")
    }
}

private struct AttentionMark: View {
    let reason: Attention.Reason

    var body: some View {
        switch reason {
        case .finishedUnread:
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
        case .question:
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Has a question")
        }
    }
}

private struct AttentionRow: View {
    let attention: Attention

    var body: some View {
        HStack(spacing: 8) {
            AttentionMark(reason: attention.reason)
                .font(.subheadline)
                .frame(width: AttentionRow.markWidth)
            Text(attention.title ?? "Untitled")
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let completedAt = attention.completedAtUnixSeconds.map(Date.init(timeIntervalSince1970:)) {
                Text(completedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static let markWidth: CGFloat = 18
}

private struct MoreCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count) more")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, AttentionRow.markWidth + 8)
        }
    }
}

private struct CompactStatus: View {
    let state: ContentState
    let size: CGFloat

    var body: some View {
        let waiting = state.attentionCount ?? state.attention?.count ?? 0
        if state.attention?.first?.reason == .question {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityLabel("Has a question")
        } else if waiting > 0 {
            Text("\(waiting)")
                .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.tint, in: Circle())
                .accessibilityLabel("\(waiting) waiting")
        } else if state.activeTaskCount > 0 {
            RunningIndicator(count: state.activeTaskCount, size: size)
        }
    }
}

private struct ActiveTasksLockScreen: View {
    let attributes: RemoteCoderActiveTasksAttributes
    let state: ContentState

    var body: some View {
        let rows = state.attention ?? []

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LiveActivityGlyph(size: 20, cornerRadius: 5)

                // With several gateways running turns, the host name is
                // what tells two identical-looking activities apart.
                Text(attributes.hostName ?? "RemoteCoder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if state.activeTaskCount > 0 {
                    RunningIndicator(count: state.activeTaskCount, size: 22)
                }
            }

            if rows.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { attention in
                        if let url = attributes.url(for: attention) {
                            Link(destination: url) { AttentionRow(attention: attention) }
                        } else {
                            AttentionRow(attention: attention)
                        }
                    }
                    MoreCount(count: (state.attentionCount ?? rows.count) - rows.count)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct RemoteCoderActiveTasksWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteCoderActiveTasksAttributes.self) { context in
            ActiveTasksLockScreen(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.tapURL(for: context.state))
        } dynamicIsland: { context in
            let state = context.state
            let lead = state.attention?.first

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityGlyph(size: 24, cornerRadius: 6)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if state.activeTaskCount > 0 {
                        RunningIndicator(count: state.activeTaskCount, size: 24)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if let lead {
                        VStack(alignment: .leading, spacing: 4) {
                            AttentionRow(attention: lead)
                            MoreCount(count: (state.attentionCount ?? 1) - 1)
                        }
                    }
                }
            } compactLeading: {
                LiveActivityGlyph(size: 18, cornerRadius: 4)
            } compactTrailing: {
                CompactStatus(state: state, size: 18)
            } minimal: {
                CompactStatus(state: state, size: 16)
            }
            .keylineTint(lead.map { $0.reason == .question ? Color.orange : Color.accentColor })
            .widgetURL(context.attributes.tapURL(for: state))
        }
    }
}
