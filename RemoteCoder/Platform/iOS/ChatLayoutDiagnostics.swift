import Combine
import SwiftUI
import UIKit

struct ChatLayoutContext: Equatable {
    let description: String

    @MainActor
    init(window: ChatWindowModel?) {
        let screen = window?.selectedScreen
        let thread = screen.map { $0.activeSessionID ?? "new-chat" } ?? "unknown"
        description = "chatWindow=\(window?.id.uuidString ?? "unattached") host=\(screen?.hostID.uuidString ?? "none") target=\(screen?.executionTarget.id ?? "none") thread=\(thread) conversation=\(screen?.currentConversationID.uuidString ?? "none") transcript=\(screen?.transcriptIdentity ?? "none")"
    }
}

struct ChatLayoutObservation: ViewModifier {
    static let coordinateSpace = "chat-layout-diagnostics"
    let context: ChatLayoutContext
    @State private var recorder = ChatLayoutRecorder(log: AppLogger(category: "ChatLayout").notice)
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.chatLayoutRecorder, recorder)
            .onGeometryChange(for: ChatLayoutGeometry.self) {
                ChatLayoutGeometry(frame: CGRect(origin: .zero, size: $0.size), insets: $0.safeAreaInsets)
            } action: { recorder.geometry("root", $0, context: context) }
            .onChange(of: context, initial: true) { _, value in recorder.contextChanged(value) }
            .onChange(of: scenePhase, initial: true) { _, phase in recorder.phaseChanged(phase) }
            .onAppear { recorder.start(context: context) }
            .onDisappear { recorder.stop() }
            .onReceive(Publishers.MergeMany([
                UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification
            ].map { NotificationCenter.default.publisher(for: $0) })) { recorder.keyboardChanged($0) }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                recorder.sceneChanged()
            }
    }
}

extension EnvironmentValues {
    @Entry var chatLayoutRecorder: ChatLayoutRecorder?
}

extension View {
    func chatLayoutDiagnostics(_ surface: String) -> some View {
        modifier(ChatSurfaceObservation(surface: surface))
    }
}

private struct ChatSurfaceObservation: ViewModifier {
    let surface: String
    @Environment(\.chatLayoutRecorder) private var recorder

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(ChatLayoutObservation.coordinateSpace))
        } action: { recorder?.geometry(surface, .init(frame: $0, insets: nil), context: nil) }
    }
}

struct ChatLayoutGeometry: Equatable {
    let frame: CGRect
    let insets: EdgeInsets?
}

@MainActor
final class ChatLayoutRecorder {
    private struct ObservedGeometry {
        let value: ChatLayoutGeometry
        let time: Date
    }

    private let log: (String) -> Void
    private var context: ChatLayoutContext?
    private var phase = "unknown"
    private var surfaces: [String: ObservedGeometry] = [:]
    private var presentations: Set<String> = []
    private var keyboard = "unknown"
    private var drawer = "unknown"
    private var visible = false
    private var geometryObservers: [String: NSKeyValueObservation] = [:]
    private var pendingGeometry: Set<String> = []
    private var geometryTask: Task<Void, Never>?
    private var geometryDeadline: ContinuousClock.Instant?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func start(context: ChatLayoutContext) {
        self.context = context
        visible = true
        observeScenes()
        record("root-appeared")
    }

    func stop() {
        visible = false
        geometryTask?.cancel()
        geometryTask = nil
        geometryDeadline = nil
        pendingGeometry.removeAll()
        record("root-disappeared")
        geometryObservers.removeAll()
    }

    func contextChanged(_ context: ChatLayoutContext) {
        guard self.context != context else { return }
        self.context = context
        record("conversation-changed")
    }

    func phaseChanged(_ phase: ScenePhase) {
        let value = String(describing: phase)
        guard self.phase != value else { return }
        self.phase = value
        record("scene-phase")
    }

    func sceneChanged() {
        observeScenes()
        record("scene-activated")
    }

    func geometry(_ surface: String, _ geometry: ChatLayoutGeometry, context: ChatLayoutContext?) {
        if let context { contextChanged(context) }
        guard surfaces[surface]?.value != geometry else { return }
        surfaces[surface] = ObservedGeometry(value: geometry, time: .now)
        scheduleGeometry(surface)
    }

    func presentation(_ name: String, isPresented: Bool) {
        let changed = isPresented ? presentations.insert(name).inserted : presentations.remove(name) != nil
        guard changed else { return }
        record("\(name)-\(isPresented ? "appeared" : "disappeared")")
    }

    func drawerChanged(_ open: Bool) {
        let value = String(open)
        guard drawer != value else { return }
        drawer = value
        record("drawer-\(open ? "opened" : "closed")")
    }

    func keyboardChanged(_ notification: Notification) {
        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let value = "\(notification.name.rawValue) screenFrame=\(frame.map(Self.rect) ?? "unknown")"
        guard keyboard != value else { return }
        keyboard = value
        record("keyboard")
    }

    private func observeScenes() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ids = Set(scenes.map { $0.session.persistentIdentifier })
        geometryObservers = geometryObservers.filter { ids.contains($0.key) }
        for scene in scenes where geometryObservers[scene.session.persistentIdentifier] == nil {
            geometryObservers[scene.session.persistentIdentifier] = scene.observe(\.effectiveGeometry) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleGeometry("scene") }
            }
        }
    }

    private func scheduleGeometry(_ surface: String) {
        pendingGeometry.insert(surface)
        geometryDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        guard geometryTask == nil else { return }
        geometryTask = Task { [weak self] in
            while let deadline = self?.geometryDeadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled, let self, let latest = geometryDeadline else { return }
                guard latest <= ContinuousClock.now else { continue }
                let changed = pendingGeometry.sorted().joined(separator: ",")
                pendingGeometry.removeAll()
                geometryTask = nil
                geometryDeadline = nil
                record("geometry[\(changed)]")
            }
        }
    }

    private func record(_ event: String) {
        let now = Date.now
        let geometry = surfaces.sorted { $0.key < $1.key }.map {
            "\($0.key)={ageMs=\(Int(now.timeIntervalSince($0.value.time) * 1_000)),localFrame=\(Self.rect($0.value.value.frame)),insets=\($0.value.value.insets.map(Self.insets) ?? "unobserved")}"
        }.joined(separator: " ")
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let native = scenes.sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }.prefix(4).map { scene in
            let windows = scene.windows.prefix(8).map { window in
                "window=\(ObjectIdentifier(window)) type=\(Self.typeName(window)) key=\(window.isKeyWindow) hidden=\(window.isHidden) level=\(window.windowLevel.rawValue) bounds=\(Self.rect(window.bounds)) safe=\(Self.insets(window.safeAreaInsets)) \(violations(in: window)) controllers=[\(controllers(window.rootViewController, window: window))]"
            }.joined(separator: " | ")
            return "scene=\(scene.session.persistentIdentifier) state=\(scene.activationState.rawValue) orientation=\(scene.effectiveGeometry.interfaceOrientation.rawValue) windows=\(scene.windows.count)[\(windows)]"
        }.joined(separator: " || ")
        log("event=\(event) \(context?.description ?? "chatWindow=unattached thread=unknown") phase=\(phase) visible=\(visible) drawer=\(drawer) keyboard=\(keyboard) presentations=\(presentations.sorted()) geometryPending=\(geometryTask != nil) \(geometry) native=[\(native)]")
    }

    private func violations(in window: UIWindow) -> String {
        guard window.isKeyWindow else { return "" }
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let headerFrame = windowFrame("header", in: window)
        let composerFrame = windowFrame("composer", in: window)
        let header = headerFrame.map { String($0.minY < safe.minY - 1) } ?? "unknown"
        let composer = composerFrame.map { String($0.maxY > safe.maxY + ComposerMetrics.restingSafeAreaOverlap + 1) } ?? "unknown"
        return "headerOutsideSafeArea=\(header) composerOutsideSafeArea=\(composer) derivedHeaderWindowFrame=\(headerFrame.map(Self.rect) ?? "unknown") derivedComposerWindowFrame=\(composerFrame.map(Self.rect) ?? "unknown")"
    }

    private func windowFrame(_ surface: String, in window: UIWindow) -> CGRect? {
        guard let insets = surfaces["root"]?.value.insets, let frame = surfaces[surface]?.value.frame,
              let view = window.rootViewController?.viewIfLoaded, view.window === window else { return nil }
        return view.convert(frame.offsetBy(dx: insets.leading, dy: insets.top), to: window)
    }

    private func controllers(_ root: UIViewController?, window: UIWindow) -> String {
        guard let root else { return "none" }
        var pending = [root]
        var visited: Set<ObjectIdentifier> = []
        var result: [String] = []
        while !pending.isEmpty, result.count < 16 {
            let controller = pending.removeFirst()
            let id = ObjectIdentifier(controller)
            guard visited.insert(id).inserted else { continue }
            let view = controller.viewIfLoaded
            let frame = view.map { Self.rect($0.convert($0.bounds, to: window)) } ?? "unloaded"
            result.append("\(Self.typeName(controller))@\(id){parent=\(controller.parent.map { String(describing: ObjectIdentifier($0)) } ?? "none"),presented=\(controller.presentedViewController.map { String(describing: ObjectIdentifier($0)) } ?? "none"),frame=\(frame),safe=\(view.map { Self.insets($0.safeAreaInsets) } ?? "unloaded"),additional=\(Self.insets(controller.additionalSafeAreaInsets)),attached=\(view?.window === window),presenting=\(controller.isBeingPresented),dismissing=\(controller.isBeingDismissed),style=\(controller.modalPresentationStyle.rawValue)}")
            if let presented = controller.presentedViewController { pending.append(presented) }
            pending.append(contentsOf: controller.children.prefix(16))
        }
        return result.joined(separator: ";") + " remaining=\(pending.count)"
    }

    private static func typeName(_ object: AnyObject) -> String {
        String(describing: type(of: object)).split(separator: "<", maxSplits: 1).first.map(String.init) ?? "unknown"
    }

    private static func rect(_ rect: CGRect) -> String {
        "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)"
    }

    private static func insets(_ insets: UIEdgeInsets) -> String {
        "\(insets.top),\(insets.left),\(insets.bottom),\(insets.right)"
    }

    private static func insets(_ insets: EdgeInsets) -> String {
        "\(insets.top),\(insets.leading),\(insets.bottom),\(insets.trailing)"
    }
}
