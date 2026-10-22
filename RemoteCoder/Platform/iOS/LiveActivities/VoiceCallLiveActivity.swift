@preconcurrency import ActivityKit
import Foundation

@MainActor
struct VoiceCallLiveActivity {
    private let activity: Activity<RemoteCoderVoiceCallAttributes>

    var isOngoing: Bool { ![.ended, .dismissed].contains(activity.activityState) }

    static func request(callID: UUID, hostName: String) throws -> Self {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw VoiceCallUnavailable(
                message: "Voice Mode from Siri or the Action button needs Live Activities. Turn them on for RemoteCoder in Settings."
            )
        }
        do {
            return Self(activity: try Activity.request(
                attributes: RemoteCoderVoiceCallAttributes(callID: callID, startedAt: .now, hostName: hostName),
                content: ActivityContent(state: RemoteCoderVoiceCallAttributes.ContentState(), staleDate: nil, relevanceScore: 1_000)
            ))
        } catch {
            throw VoiceCallUnavailable(message: error.localizedDescription)
        }
    }

    func end() async {
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    @concurrent
    static func endOrphans() async {
        for activity in Activity<RemoteCoderVoiceCallAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
