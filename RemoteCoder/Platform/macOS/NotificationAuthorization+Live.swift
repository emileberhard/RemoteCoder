#if os(macOS)
import AppKit

extension NotificationAuthorization {
    static let live = NotificationAuthorization(
        registerForRemoteNotifications: { NSApplication.shared.registerForRemoteNotifications() }
    )
}
#endif
