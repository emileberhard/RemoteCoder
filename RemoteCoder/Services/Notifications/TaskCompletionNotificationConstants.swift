import Foundation

enum TaskCompletionNotificationConstants {
    static let apnsEnvironmentInfoPlistKey = "RemoteCoderAPNSEnvironment"
    static let userInfoPayloadKey = RemoteCoderNotificationPayloadKeys.taskCompletion
    static let deviceTokenDefaultsKey = "remoteCoder.apnsDeviceToken"
    static let completionNotificationsEnabledDefaultsKey = "taskCompletionNotificationsEnabled"

    static var apnsEnvironment: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: apnsEnvironmentInfoPlistKey) as? String else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "development" || normalized == "production" ? normalized : nil
    }
}
