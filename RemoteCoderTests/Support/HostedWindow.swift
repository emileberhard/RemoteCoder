import UIKit

@MainActor
final class HostedWindow {
    private let window: UIWindow
    private let previousWindow: UIWindow?

    init(scene: UIWindowScene) {
        previousWindow = scene.keyWindow
        window = UIWindow(windowScene: scene)
    }

    func show(_ controller: UIViewController) {
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKey()
    }
}
