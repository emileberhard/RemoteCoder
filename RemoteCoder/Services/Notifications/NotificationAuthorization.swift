import OSLog
import UserNotifications

struct NotificationAuthorization: Sendable {
    let registerForRemoteNotifications: @MainActor @Sendable () -> Void

    private static let logger = AppLogger(category: "TaskCompletionNotifications")

    func ensureAuthorizedIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized: Bool
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Self.logger.error("Notification authorization request failed: \(error.localizedDescription)")
                authorized = false
            }
        case .denied:
            authorized = false
        case .authorized, .provisional:
            authorized = true
        #if os(iOS)
        case .ephemeral:
            authorized = true
        #endif
        @unknown default:
            authorized = false
        }

        Self.logger.notice(
            "notification authorization status=\(settings.authorizationStatus.rawValue) authorized=\(authorized)"
        )
        if authorized {
            await registerForRemoteNotifications()
            Self.logger.notice("requested APNs registration")
        }

        return authorized
    }
}
