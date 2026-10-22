import Foundation
import Observation

/// The one owner of this installation's push identity and tokens. Each source
/// reports here; the workspace registers whatever changes with every host.
@MainActor
@Observable
final class PushTokenSources {
    private(set) var apns: String?
    private(set) var voipToken: String?
    private(set) var microphonePermitted = false
    private(set) var location: DeviceLocationCredentials?
    @ObservationIgnored let deviceID: String
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        apns = Self.saved(TaskCompletionNotificationConstants.deviceTokenDefaultsKey, in: defaults)
        voipToken = Self.saved(Self.voipTokenKey, in: defaults)
        location = defaults.data(forKey: Self.locationKey)
            .flatMap { try? JSONDecoder().decode(DeviceLocationCredentials.self, from: $0) }
        if let saved = defaults.string(forKey: Self.deviceIDKey), UUID(uuidString: saved) != nil {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
    }

    var voip: String? { microphonePermitted ? voipToken : nil }

    func credentials(alertsEnabled: Bool) -> DeviceCredentials? {
        guard let environment = TaskCompletionNotificationConstants.apnsEnvironment,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return DeviceCredentials(
            deviceID: deviceID, bundleID: bundleID, apnsEnvironment: environment,
            alertToken: alertsEnabled ? apns : nil, voipToken: voip, location: location
        )
    }

    func receiveAPNs(_ deviceToken: Data) {
        let token = Self.hex(deviceToken)
        defaults.set(token, forKey: TaskCompletionNotificationConstants.deviceTokenDefaultsKey)
        if apns != token { apns = token }
    }

    func receiveVoIP(_ deviceToken: Data) {
        let token = Self.hex(deviceToken)
        defaults.set(token, forKey: Self.voipTokenKey)
        if voipToken != token { voipToken = token }
    }

    func invalidateVoIP() {
        defaults.removeObject(forKey: Self.voipTokenKey)
        voipToken = nil
    }

    func setMicrophonePermitted(_ permitted: Bool) {
        if microphonePermitted != permitted { microphonePermitted = permitted }
    }

    func receiveLocation(_ credentials: DeviceLocationCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        defaults.set(data, forKey: Self.locationKey)
        if location != credentials { location = credentials }
    }

    private static let deviceIDKey = "pushDevice.id"
    private static let voipTokenKey = "incomingCalls.voipToken"
    private static let locationKey = "pushDevice.location"

    private static func saved(_ key: String, in defaults: UserDefaults) -> String? {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
