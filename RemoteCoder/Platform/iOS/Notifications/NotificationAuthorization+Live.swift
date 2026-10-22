import UIKit

extension NotificationAuthorization {
    static let live = NotificationAuthorization(
        registerForRemoteNotifications: { UIApplication.shared.registerForRemoteNotifications() }
    )
}
