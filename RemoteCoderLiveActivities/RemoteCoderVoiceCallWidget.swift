import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private typealias CallState = RemoteCoderVoiceCallAttributes.ContentState

private extension CallState {
    var displayTitle: String { title ?? "Voice Mode" }

    var symbolName: String {
        if isMuted { return "mic.slash.fill" }
        return switch phase {
        case .connecting, .reconnecting: "ellipsis"
        case .listening: "mic.fill"
        case .speaking: "waveform"
        }
    }

    var status: String {
        switch phase {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .listening: isMuted ? "Muted" : "Listening"
        case .speaking: "Speaking"
        }
    }
}

private struct CallTimer: View {
    let startedAt: Date

    var body: some View {
        Text(startedAt, style: .timer)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct CallSymbol: View {
    let state: CallState

    var body: some View {
        Image(systemName: state.symbolName)
            .foregroundStyle(state.isMuted ? Color.red : Color.orange)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(state.status)
    }
}

private struct CallStatusLine: View {
    let state: CallState
    let hostName: String?

    var body: some View {
        HStack(spacing: 5) {
            CallSymbol(state: state)
            Text(hostName.map { "\($0) · \(state.status)" } ?? state.status)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

private struct CallControls: View {
    let callID: UUID
    let state: CallState

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: SetVoiceCallMutedIntent(callID: callID, muted: !state.isMuted)) {
                Label(state.isMuted ? "Unmute" : "Mute", systemImage: state.isMuted ? "mic.fill" : "mic.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(state.isMuted ? .orange : .primary)

            Button(intent: EndVoiceCallIntent(callID: callID)) {
                Label("End", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .font(.subheadline.weight(.semibold))
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
    }
}

private struct Caption: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.footnote)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VoiceCallLockScreen: View {
    let attributes: RemoteCoderVoiceCallAttributes
    let state: CallState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LiveActivityGlyph(size: 28, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    CallStatusLine(state: state, hostName: attributes.hostName)
                        .font(.caption)
                }
                Spacer(minLength: 8)
                CallTimer(startedAt: attributes.startedAt)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 80, alignment: .trailing)
            }
            Caption(text: state.caption)
            CallControls(callID: attributes.callID, state: state)
        }
        .padding(14)
    }
}

private struct CompactLeading: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let state: CallState

    var body: some View {
        if isLimitedInWidth {
            CallSymbol(state: state)
        } else {
            LiveActivityGlyph(size: 18, cornerRadius: 4)
        }
    }
}

private struct CompactTrailing: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let state: CallState

    var body: some View {
        if !isLimitedInWidth {
            CallSymbol(state: state)
        }
    }
}

struct RemoteCoderVoiceCallWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteCoderVoiceCallAttributes.self) { context in
            VoiceCallLockScreen(attributes: context.attributes, state: context.state)
                .widgetURL(RemoteCoderDeepLinks.url(forVoiceCall: context.attributes.callID))
        } dynamicIsland: { context in
            let state = context.state

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityGlyph(size: 26, cornerRadius: 7)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallTimer(startedAt: context.attributes.startedAt)
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 64, alignment: .trailing)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        CallStatusLine(state: state, hostName: nil)
                            .font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        Caption(text: state.caption)
                        CallControls(callID: context.attributes.callID, state: state)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                CompactLeading(state: state)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                CallSymbol(state: state)
            }
            .keylineTint(.orange)
            .widgetURL(RemoteCoderDeepLinks.url(forVoiceCall: context.attributes.callID))
        }
    }
}
