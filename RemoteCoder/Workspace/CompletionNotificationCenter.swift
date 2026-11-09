import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CompletionNotificationCenter {
    private static let ledgerKey = "remoteCoder.presentedNotificationEvents.v1"

    private(set) var banner: ForegroundNotificationPresentation.Banner?

    @ObservationIgnored let authorization: NotificationAuthorization
    @ObservationIgnored private var ledger: ForegroundNotificationPresentation.Ledger
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = AppLogger(category: "CompletionNotifications")

    init(defaults: UserDefaults, authorization: NotificationAuthorization) {
        self.defaults = defaults
        self.authorization = authorization
        ledger = .init(eventIDs: defaults.stringArray(forKey: Self.ledgerKey) ?? [])
    }

    func consume(_ payload: TaskCompletionNotificationPayload) -> Bool {
        let fresh = ledger.consume(payload)
        if fresh { defaults.set(ledger.eventIDs, forKey: Self.ledgerKey) }
        return fresh
    }

    func receive(_ delivery: ForegroundNotificationPresentation.Delivery, applicationIsActive: Bool,
                 isOpen: (TaskCompletionNotificationPayload) -> Bool) -> ForegroundNotificationPresentation.Disposition {
        if let payload = delivery.payload, !consume(payload) { return .suppressed }
        guard applicationIsActive else { return .system }
        if let payload = delivery.payload, isOpen(payload) {
            logger.notice("notification suppressed for open conversation event=\(payload.eventID)")
            return .suppressed
        }
        return presentInForeground(delivery)
    }

    func present(_ delivery: ForegroundNotificationPresentation.Delivery) {
        dismissTask?.cancel()
        dismissTask = nil
        banner = .init(delivery: delivery)
        logger.notice("notification in-app event=\(delivery.payload?.eventID ?? "unattributed")")
    }

    /// Expiry begins only when the scene's banner renderer is actually mounted.
    func bannerDidAppear() {
        startExpiry()
    }

    func holdExpiry() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func resumeExpiry() {
        startExpiry()
    }

    private func startExpiry() {
        guard let id = banner?.id, dismissTask == nil else { return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.banner?.id == id else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        banner = nil
    }

    func dismissIfOpen(_ isOpen: (TaskCompletionNotificationPayload) -> Bool) {
        if let payload = banner?.payload, isOpen(payload) { dismiss() }
    }
}
