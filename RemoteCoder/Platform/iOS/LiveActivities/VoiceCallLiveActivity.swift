@preconcurrency import ActivityKit
import Foundation

@MainActor
final class VoiceCallLiveActivity {
    typealias ContentState = RemoteCoderVoiceCallAttributes.ContentState

    private let activity: Activity<RemoteCoderVoiceCallAttributes>
    private var shown: ContentState
    private var pending: ContentState?
    private var updates: Task<Void, Never>?

    var isOngoing: Bool { ![.ended, .dismissed].contains(activity.activityState) }

    private init(activity: Activity<RemoteCoderVoiceCallAttributes>, state: ContentState) {
        self.activity = activity
        shown = state
    }

    static func request(callID: UUID, hostName: String, state: ContentState) throws -> VoiceCallLiveActivity {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw VoiceCallUnavailable(
                message: "Voice Mode from Siri or the Action button needs Live Activities. Turn them on for RemoteCoder in Settings."
            )
        }
        do {
            let activity = try Activity.request(
                attributes: RemoteCoderVoiceCallAttributes(
                    callID: callID, startedAt: .now, hostName: hostName.prefix(utf8Bytes: 64)
                ),
                content: Self.content(state)
            )
            return VoiceCallLiveActivity(activity: activity, state: state)
        } catch {
            throw VoiceCallUnavailable(message: error.localizedDescription)
        }
    }

    func show(_ state: ContentState) {
        guard state != (pending ?? shown) else { return }
        pending = state
        guard updates == nil else { return }
        updates = Task { [weak self] in await self?.publishPending() }
    }

    func end() async {
        pending = nil
        await updates?.value
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func publishPending() async {
        while let next = pending {
            pending = nil
            shown = next
            await activity.update(Self.content(next))
        }
        updates = nil
    }

    private static func content(_ state: ContentState) -> ActivityContent<ContentState> {
        var bounded = state
        bounded.title = state.title?.prefix(utf8Bytes: 128)
        bounded.caption = state.caption?.prefix(utf8Bytes: 512)
        return ActivityContent(state: bounded, staleDate: nil, relevanceScore: 1_000)
    }

    @concurrent
    static func endOrphans() async {
        for activity in Activity<RemoteCoderVoiceCallAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

private extension String {
    func prefix(utf8Bytes limit: Int) -> String {
        var bytes = 0
        var end = startIndex
        for character in self {
            bytes += character.utf8.count
            guard bytes <= limit else { break }
            end = index(after: end)
        }
        return String(self[..<end])
    }
}
