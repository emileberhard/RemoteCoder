#if os(macOS)
import AppKit
import OSLog
import UserNotifications

@MainActor
final class RemoteCoderMacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let app = RemoteCoderAppModel.live()
    let zoom = InterfaceZoom(defaults: AppStorageScope.current.defaults)
    private(set) lazy var attention = AttentionCenter(workspace: app.workspace)
    private lazy var statusItem = AttentionStatusItem(attention: attention)
    private(set) lazy var quickEntry = QuickEntry(workspace: app.workspace, theme: app.theme, zoom: zoom, defaults: AppStorageScope.current.defaults)
    private lazy var keyMonitor = AppKeyMonitor(zoom: zoom)
    private var terminationTask: Task<Void, Never>?
    private var terminationDrain: TerminationDrain?
    private var resumeAfterDrainTask: Task<Void, Never>?
    private var isFinishingTermination = false
    private var quitRequest = QuitRequest.interactive
    private var terminationSignal: (any DispatchSourceSignal)?
    private static let logger = AppLogger(category: "AppDelegate")
    private static let interactiveQuitWait = Duration.seconds(5)
    private static let unattendedQuitWait = Duration.seconds(60)

    func applicationWillFinishLaunching(_ notification: Notification) {
        app.theme.retainedTranscripts = app.workspace.retainedTranscripts
        app.start()
        UNUserNotificationCenter.current().delegate = self
        attention.start()
        quickEntry.start()
        keyMonitor.start()
        terminationSignal = quitOnSIGTERM()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        app.synchronizeHosts()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        let drain: TerminationDrain
        if let current = terminationDrain { drain = current }
        else {
            app.workspace.beginTermination()
            drain = TerminationDrain { [app] in await app.workspace.flushForTermination() }
            terminationDrain = drain
        }
        terminationTask = Task {
            let started = ContinuousClock.now
            var presentation = await drain.presentation(after: Self.interactiveQuitWait)
            let shownFailures = persistenceFailures(presentation)
            if quitRequest == .interactive, !shownFailures.isEmpty {
                Self.logger.error("Quit persistence incomplete: \(shownFailures.joined(separator: "; "))")
                if await askToKeepOpen(shownFailures) == .alertFirstButtonReturn {
                    Self.logger.notice("Quit cancelled; waiting for admitted persistence to drain")
                    terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: false)
                    resumeWhenDrained(drain)
                    return
                }
            }
            if presentation == .pending, quitRequest == .unattended {
                presentation = await drain.presentation(after: Self.unattendedQuitWait - Self.interactiveQuitWait)
                Self.logger.notice("Unattended quit waited \(String(describing: ContinuousClock.now - started)) for persistence")
            }
            let failures = persistenceFailures(presentation)
            if !failures.isEmpty {
                if quitRequest == .unattended {
                    Self.logger.error("Quit persistence incomplete: \(failures.joined(separator: "; "))")
                }
                Self.logger.notice("Quit anyway after incomplete persistence (\(String(describing: self.quitRequest)) quit)")
            }
            await DiagnosticsOutbox.shared.persistPending()
            isFinishingTermination = true
            #if RC_PERF_HARNESS
            if case .finished = presentation, AppStorageScope.current.isBenchmark {
                let models = app.workspace.models
                app.terminate()
                for model in models { await model.retire() }
                await DiagnosticsOutbox.shared.stopPumping()
                do { try await AppStorageScope.current.discardBenchmark() }
                catch { Self.logger.error("Benchmark storage cleanup failed: \(error.localizedDescription)") }
            }
            #endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func persistenceFailures(_ presentation: TerminationDrain.Presentation) -> [String] {
        switch presentation {
        case .finished(let failures):
            return failures
        case .pending:
            let pending = app.workspace.pendingTerminationOperations
            return (pending.isEmpty ? ["Final persistence result"] : pending).map { $0 + " is still pending" }
        }
    }

    private func askToKeepOpen(_ failures: [String]) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    guard self.quitRequest == .interactive else { return continuation.resume(returning: .abort) }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Some changes could not be saved"
                    alert.informativeText = failures.joined(separator: "\n")
                    alert.addButton(withTitle: "Keep Open")
                    alert.addButton(withTitle: "Quit Anyway")
                    continuation.resume(returning: alert.runModal())
                }
            }
        }
    }

    private func resumeWhenDrained(_ drain: TerminationDrain) {
        guard resumeAfterDrainTask == nil else { return }
        resumeAfterDrainTask = Task {
            let failures = await drain.drain()
            defer { resumeAfterDrainTask = nil }
            guard !isFinishingTermination, terminationTask == nil else { return }
            if !failures.isEmpty {
                Self.logger.error("Kept-open persistence failed: \(failures.joined(separator: "; "))")
            }
            app.workspace.resumeAfterTermination()
            terminationDrain = nil
            Self.logger.notice("Kept-open app resumed after admitted persistence drained")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyMonitor.stop()
        quickEntry.stop()
        statusItem.stop()
        attention.stop()
        app.terminate()
    }

    private func quitOnSIGTERM() -> any DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            self.quitRequest = .unattended
            if NSApplication.shared.modalWindow != nil { NSApplication.shared.abortModal() }
            RunLoop.main.perform {
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
        }
        source.resume()
        return source
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AttentionDockMenu.make(attention.summary, target: self, action: #selector(performDockMenuItem(_:)))
    }

    @objc private func performDockMenuItem(_ item: NSMenuItem) {
        guard let action = item.representedObject as? AttentionCenter.Action else { return }
        attention.perform(action)
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        app.workspace.pushTokens.receiveAPNs(deviceToken)
        Self.logger.info("Registered for remote notifications.")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        Task { @MainActor in
            let payload = content.userInfo[TaskCompletionNotificationConstants.userInfoPayloadKey]
            let delivery = await ForegroundNotificationPresentation.prepare(
                payloadJSON: payload as? String, title: content.title, body: content.body,
                containsPayload: payload != nil
            )
            if let field = delivery.decodingFailure {
                Self.logger.error("notification payload unreadable field=\(field)")
            }
            switch app.workspace.receiveNotification(delivery, applicationIsActive: NSApplication.shared.isActive) {
            case .system, .inApp: completionHandler([.banner, .list, .sound])
            case .suppressed: completionHandler([])
            }
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
        let payloadJSON = rawPayload as? String ?? "null"
        Task { @MainActor in
            app.workspace.events.summon(.completionNotificationTap(payloadJSON: payloadJSON))
            Self.logger.notice("Received task completion notification tap.")
            completionHandler()
        }
    }
}

private enum QuitRequest {
    case interactive
    case unattended
}
#endif
