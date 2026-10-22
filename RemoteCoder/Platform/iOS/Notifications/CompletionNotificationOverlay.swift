import Observation
import SwiftUI
import UIKit

/// A scene-owned in-app surface above sheets and full-screen covers. It never
/// becomes key, and only the banner's measured rectangle accepts touches.
struct CompletionNotificationOverlay: UIViewRepresentable {
    let workspace: ChatWorkspaceModel
    @Environment(AppThemeStore.self) private var theme

    func makeUIView(context: Context) -> Attachment {
        Attachment(workspace: workspace, theme: theme)
    }

    func updateUIView(_ view: Attachment, context: Context) {
        view.attachIfNeeded()
    }

    static func dismantleUIView(_ view: Attachment, coordinator: ()) {
        view.detach()
    }

    final class Attachment: UIView {
        private let workspace: ChatWorkspaceModel
        private let theme: AppThemeStore
        private let surfaceID = UUID()
        private weak var contentWindow: UIWindow?
        private var bannerWindow: CompletionBannerWindow?
        private var activationObserver: (any NSObjectProtocol)?
        private var visibilityTask: Task<Void, Never>?

        init(workspace: ChatWorkspaceModel, theme: AppThemeStore) {
            self.workspace = workspace
            self.theme = theme
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            // A full-screen presentation can temporarily detach the presenting
            // view. Keep its scene surface until SwiftUI dismantles this owner.
            guard let contentWindow = window, let scene = contentWindow.windowScene else { return }
            self.contentWindow = contentWindow
            guard bannerWindow?.windowScene !== scene else { return }
            detach()
            self.contentWindow = contentWindow
            let overlay = CompletionBannerWindow(windowScene: scene)
            overlay.isHidden = true
            let content = Content(workspace: workspace, surfaceID: surfaceID, onBoundsChange: { [weak overlay] bounds in
                overlay?.bannerBounds = bounds
            }, onTap: { [weak self] payload in
                guard let self else { return }
                Task { await self.workspace.handleCompletionNotificationTap(payload: payload) }
            })
            let host = UIHostingController(rootView: content.environment(theme))
            host.view.backgroundColor = .clear
            overlay.backgroundColor = .clear
            overlay.windowLevel = .normal + 1
            overlay.rootViewController = host
            bannerWindow = overlay
            workspace.notificationSurfaces.register(id: surfaceID) { [weak self] in
                await Self.dismissPresentations(from: self?.contentWindow?.rootViewController)
            }
            activationObserver = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification, object: scene, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.workspace.notificationSurfaces.markKey(self.surfaceID)
                }
            }
            let workspace = self.workspace
            let surfaceID = self.surfaceID
            visibilityTask = Task { [weak overlay] in
                for await presentsNotification in Observations({ @MainActor in
                    workspace.notifications.banner != nil && workspace.notificationSurfaces.keySurfaceID == surfaceID
                }) {
                    guard !Task.isCancelled, let overlay else { return }
                    overlay.isHidden = !presentsNotification
                    if !presentsNotification { overlay.bannerBounds = .zero }
                }
            }
        }

        /// UIKit can refuse a dismissal during presentation without calling its
        /// completion. Observe bounded state instead; cancellation and a newer
        /// navigation never leave a suspended continuation behind.
        static func dismissPresentations(from presenter: UIViewController?, timeout: Duration = .seconds(2)) async -> Bool {
            guard let presenter else { return true }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while let presented = presenter.presentedViewController {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                if !presented.isBeingPresented && !presented.isBeingDismissed && presented.transitionCoordinator == nil {
                    presenter.dismiss(animated: true)
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            }
            return true
        }

        func detach() {
            visibilityTask?.cancel()
            visibilityTask = nil
            workspace.notificationSurfaces.unregister(id: surfaceID)
            if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
            activationObserver = nil
            bannerWindow?.isHidden = true
            bannerWindow?.rootViewController = nil
            bannerWindow = nil
            contentWindow = nil
        }
    }

    private struct Content: View {
        let workspace: ChatWorkspaceModel
        let surfaceID: UUID
        let onBoundsChange: (CGRect) -> Void
        let onTap: (TaskCompletionNotificationPayload) -> Void
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var drag: CGSize = .zero
        @State private var isLeaving = false

        private static let releaseProjectionSeconds: CGFloat = 0.2
        private static let dismissDistance: CGFloat = 56
        private static let exitDistance: CGFloat = 480

        private var banner: ForegroundNotificationPresentation.Banner? {
            workspace.notificationSurfaces.keySurfaceID == surfaceID ? workspace.notifications.banner : nil
        }

        var body: some View {
            VStack {
                if let notification = banner {
                    CompletionBanner(notification: notification) {
                        if let payload = notification.payload { onTap(payload) }
                    }
                        .frame(maxWidth: 600)
                        .offset(drag)
                        .opacity(isLeaving ? 0 : 1 - min(hypot(drag.width, drag.height) / 400, 0.35))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onBoundsChange($0) }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .id(notification.id)
                        .onAppear { workspace.notifications.bannerDidAppear() }
                        .accessibilityAction(named: "Dismiss") { dismiss(notification.id) }
                        .accessibilityAction(.escape) { dismiss(notification.id) }
                        .accessibilityIdentifier("completion-notification-banner")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .gesture(BannerSwipeGesture(onBegan: beginSwipe, onChanged: { drag = $0 }, onEnded: endSwipe))
            .animation(.smooth(duration: 0.3), value: banner?.id)
            .onChange(of: banner?.id) {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    drag = .zero
                    isLeaving = false
                }
            }
            .onChange(of: banner == nil) { _, empty in
                if empty { onBoundsChange(.zero) }
            }
        }

        private func beginSwipe() {
            guard banner != nil, !isLeaving else { return }
            workspace.notifications.holdExpiry()
        }

        private func endSwipe(translation: CGSize, velocity: CGSize) {
            guard let id = banner?.id, !isLeaving else { return }
            let projected = CGSize(width: translation.width + velocity.width * Self.releaseProjectionSeconds,
                                   height: translation.height + velocity.height * Self.releaseProjectionSeconds)
            let projectedDistance = hypot(projected.width, projected.height)
            guard projectedDistance > Self.dismissDistance else {
                withAnimation(reduceMotion ? .smooth(duration: 0.2) : .spring(duration: 0.35, bounce: 0.25)) { drag = .zero }
                workspace.notifications.resumeExpiry()
                return
            }
            let exit = CGSize(width: projected.width / projectedDistance * Self.exitDistance,
                              height: projected.height / projectedDistance * Self.exitDistance)
            let remaining = max(hypot(exit.width - translation.width, exit.height - translation.height), 1)
            let speed = hypot(velocity.width, velocity.height)
            let animation: Animation = reduceMotion ? .easeOut(duration: 0.15)
                : .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: min(speed / remaining, 12))
            withAnimation(animation) {
                if !reduceMotion { drag = exit }
                isLeaving = true
            } completion: {
                guard workspace.notifications.banner?.id == id else { return }
                workspace.notifications.dismiss()
            }
        }

        private func dismiss(_ id: UUID) {
            guard workspace.notifications.banner?.id == id else { return }
            workspace.notifications.dismiss()
        }
    }
}

private struct BannerSwipeGesture: UIGestureRecognizerRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: (_ translation: CGSize, _ velocity: CGSize) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        UIPanGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = context.converter.localTranslation.map { CGSize(width: $0.x, height: $0.y) } ?? .zero
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(translation)
        case .changed:
            onChanged(translation)
        case .ended:
            let velocity = context.converter.localVelocity.map { CGSize(width: $0.x, height: $0.y) } ?? .zero
            onEnded(translation, velocity)
        case .cancelled, .failed:
            onEnded(.zero, .zero)
        default:
            break
        }
    }
}

final class CompletionBannerWindow: UIWindow {
    var bannerBounds: CGRect = .zero
    override var canBecomeKey: Bool { false }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bannerBounds.contains(point)
    }
}
