import AppIntents
import Foundation

@MainActor
protocol VoiceCallControls: AnyObject, Sendable {
    func setMuted(_ muted: Bool, callID: UUID) async
    func endCall(callID: UUID) async
}

struct InvalidVoiceCallID: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "This voice call control is no longer valid." }
}

struct SetVoiceCallMutedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute Voice Call"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.background]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    @Parameter(title: "Call")
    var callID: String

    @Parameter(title: "Muted")
    var muted: Bool

    @Dependency private var calls: any VoiceCallControls

    init() {}

    init(callID: UUID, muted: Bool) {
        self.callID = callID.uuidString
        self.muted = muted
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: callID) else { throw InvalidVoiceCallID() }
        await calls.setMuted(muted, callID: id)
        return .result()
    }
}

struct EndVoiceCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Voice Call"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.background]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    @Parameter(title: "Call")
    var callID: String

    @Dependency private var calls: any VoiceCallControls

    init() {}

    init(callID: UUID) {
        self.callID = callID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: callID) else { throw InvalidVoiceCallID() }
        await calls.endCall(callID: id)
        return .result()
    }
}
