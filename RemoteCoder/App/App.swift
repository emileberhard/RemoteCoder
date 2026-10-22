import AppIntents
import OSLog
import SwiftUI
import UIKit
import UserNotifications

final class RemoteCoderAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let app = RemoteCoderAppModel.live()
    private static let logger = Logger(subsystem: "RemoteCoder", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDependencyManager.shared.add(dependency: self.app.workspace)
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        VoiceModeDiagnostics.log("app delegate launch started")
        app.start()
        UNUserNotificationCenter.current().delegate = self

        VoiceModeDiagnostics.log("app delegate launch completed")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        app.terminate()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        Task { @MainActor in
            completionHandler(await Self.foregroundNotificationOptions(
                userInfo: content.userInfo, title: content.title, body: content.body,
                applicationIsActive: { [app] in app.isApplicationActive },
                workspace: app.workspace
            ))
        }
    }

    /// The delegate's presentation boundary, injectable for lifecycle regression
    /// tests without registering a device or building the app model.
    static func foregroundNotificationOptions(
        userInfo: [AnyHashable: Any], title: String = "", body: String = "",
        applicationIsActive: @MainActor () -> Bool,
        workspace: ChatWorkspaceModel
    ) async -> UNNotificationPresentationOptions {
        let delivery = await ForegroundNotificationPresentation.prepare(
            payloadJSON: userInfo[TaskCompletionNotificationConstants.userInfoPayloadKey] as? String,
            title: title, body: body,
            containsPayload: userInfo[TaskCompletionNotificationConstants.userInfoPayloadKey] != nil
        )
        if let field = delivery.decodingFailure {
            Self.logger.error("notification payload unreadable field=\(field, privacy: .public)")
        }
        // Re-read UIKit after decoding: an inactive callback uses the system
        // surface; it must never consume a banner invisible during the transition.
        switch workspace.receiveNotification(delivery, applicationIsActive: applicationIsActive()) {
        case .system: return [.banner, .list, .sound]
        case .suppressed: return []
        case .inApp:
            // Explicit spoken notifications retain their requested audio without
            // adding a second visual surface above the in-app banner.
            return userInfo[RemoteCoderNotificationAudioKeys.url] is String
                && userInfo[RemoteCoderNotificationAudioKeys.filename] is String ? [.sound] : []
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let rawPayload = userInfo[TaskCompletionNotificationConstants.userInfoPayloadKey] else {
            completionHandler()
            return
        }
        // Preserve an unreadable tap through cold launch too, without storing
        // arbitrary payload contents or inventing a conversation identity.
        let payloadJSON = rawPayload as? String ?? "null"

        Task { @MainActor in
            app.handleNotificationTap(payloadJSON: payloadJSON)
            Self.logger.notice("Received task completion notification tap.")
            completionHandler()
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            app.workspace.pushTokens.receiveAPNs(deviceToken)
        }
        Self.logger.info("Registered for remote notifications.")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.logger.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
    }
}

@main
struct RemoteCoderApp: App {
    @UIApplicationDelegateAdaptor(RemoteCoderAppDelegate.self) private var appDelegate

    init() {
        VoiceModeDiagnostics.log("app init")
    }

    var body: some Scene {
        WindowGroup(for: ConversationWindowValue.self) { $window in
            WindowRoot(app: appDelegate.app, value: $window)
        }
    }
}

private struct WindowRoot: View {
    let app: RemoteCoderAppModel
    @Binding var value: ConversationWindowValue?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-html-visual-fixture") {
                HTMLVisualFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-mermaid-preview-fixture") {
                MermaidPreviewFixture()
            } else {
                ChatRootView(workspace: app.workspace, sceneValue: $value)
            }
            #else
            ChatRootView(workspace: app.workspace, sceneValue: $value)
            #endif
        }
        .environment(app.workspace.settings)
        .environment(app.workspace.modelPickerPreferences)
        .environment(app.theme)
        .environment(app.liveNavigationSetup)
        .environment(\.appEnergyPolicy, app.energy.policy)
        .environment(\.siteIcons, app.workspace.siteIcons)
        .modifier(SceneLifecycle(app: app))
        .background { HapticOutput(voiceCall: app.voiceCalls.call) }
        .onAppear {
            guard supportsMultipleWindows else { return }
            app.workspace.events.attach(openWindow: { openWindow(value: $0) })
        }
    }
}

private struct SceneLifecycle: ViewModifier {
    let app: RemoteCoderAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                Task { await app.apply(phase, scene: sceneID) }
            }
            .onDisappear {
                Task { await app.detach(scene: sceneID) }
            }
    }
}
