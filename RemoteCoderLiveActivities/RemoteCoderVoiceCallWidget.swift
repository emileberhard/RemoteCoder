import ActivityKit
import SwiftUI
import WidgetKit

private struct VoiceCallTimer: View {
    let startedAt: Date

    var body: some View {
        Text(startedAt, style: .timer)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct VoiceCallLockScreen: View {
    let attributes: RemoteCoderVoiceCallAttributes

    var body: some View {
        HStack(spacing: 10) {
            LiveActivityGlyph(size: 28, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Mode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(attributes.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            VoiceCallTimer(startedAt: attributes.startedAt)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct RemoteCoderVoiceCallWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteCoderVoiceCallAttributes.self) { context in
            VoiceCallLockScreen(attributes: context.attributes)
                .widgetURL(RemoteCoderDeepLinks.url(forVoiceCall: context.attributes.callID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityGlyph(size: 24, cornerRadius: 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.hostName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceCallTimer(startedAt: context.attributes.startedAt)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: 64, alignment: .trailing)
                }
            } compactLeading: {
                LiveActivityGlyph(size: 18, cornerRadius: 4)
            } compactTrailing: {
                VoiceCallTimer(startedAt: context.attributes.startedAt)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 44, alignment: .trailing)
            } minimal: {
                Image(systemName: "waveform")
                    .accessibilityLabel("Voice Mode")
            }
            .widgetURL(RemoteCoderDeepLinks.url(forVoiceCall: context.attributes.callID))
        }
    }
}
