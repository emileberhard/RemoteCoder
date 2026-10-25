import Foundation
import Observation
import OSLog

enum ExternalEvent: Equatable, Sendable {
    case quickAction(RemoteCoderQuickActionRequest)
    case presentVoiceCall(UUID)
    case open(ConversationWindowValue)
    case sharedItems(UUID)
    case lockedCameraCaptures
    case completionNotificationTap(payloadJSON: String)

    var expires: Bool {
        if case .completionNotificationTap = self { return false }
        return true
    }
}

@MainActor
@Observable
final class ExternalEventRouter {
    struct Screen {
        let presents: @MainActor (ConversationWindowValue) -> Bool
        let perform: @MainActor (ExternalEvent) -> Void
    }

    private struct Pending {
        let event: ExternalEvent
        let receivedAt: Date
    }

    static let maximumAge: TimeInterval = 60

    @ObservationIgnored private var screens: [UUID: Screen] = [:]
    @ObservationIgnored private var activeScreens: Set<UUID> = []
    private(set) var keyScreenID: UUID?
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var isNavigationReady = false
    @ObservationIgnored private var openWindow: (@MainActor (ConversationWindowValue) -> Void)?
    @ObservationIgnored private var mainWindowOpener: (@MainActor () -> Void)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let logger = AppLogger(category: "ExternalEvents")

    init(now: @escaping @MainActor () -> Date) {
        self.now = now
    }

    func attach(openWindow: @escaping @MainActor (ConversationWindowValue) -> Void) {
        self.openWindow = openWindow
    }

    func attach(openMainWindow: @escaping @MainActor () -> Void) {
        mainWindowOpener = openMainWindow
    }

    var hasPendingCompletionTap: Bool {
        if case .completionNotificationTap = pending?.event { return true }
        return false
    }

    func setNavigationReady() {
        isNavigationReady = true
        deliverPending()
    }

    func register(_ screen: Screen, id: UUID) {
        screens[id] = screen
        deliverPending()
    }

    func unregister(id: UUID) {
        screens[id] = nil
        activeScreens.remove(id)
        if keyScreenID == id { keyScreenID = activeScreens.first }
    }

    func setActive(_ isActive: Bool, screen id: UUID) {
        if isActive {
            activeScreens.insert(id)
            keyScreenID = id
            deliverPending()
        } else {
            activeScreens.remove(id)
            if keyScreenID == id { keyScreenID = activeScreens.first }
        }
    }

    func setOpen(screen id: UUID) {
        activeScreens.insert(id)
        if keyScreen == nil { keyScreenID = id }
        deliverPending()
    }

    func setKey(screen id: UUID) {
        activeScreens.insert(id)
        keyScreenID = id
        deliverPending()
    }

    func receive(_ event: ExternalEvent) {
        if case .quickAction(let request) = event, request.action == .voiceChat {
            VoiceModeDiagnostics.log("voice request received fresh=\(request.startsFreshVoiceChat)")
        }
        if case .presentVoiceCall(let callID) = event {
            VoiceModeDiagnostics.log("voice call presentation received call=\(callID)")
        }
        pending = Pending(event: event, receivedAt: now())
        deliverPending()
    }

    func summon(_ event: ExternalEvent) {
        guard let openWindow else { return receive(event) }
        switch event {
        case .open(.newChat(let slot)):
            openWindow(.newChat(slot: slot))
        case .open(let value) where screens.isEmpty:
            openWindow(value)
        default:
            receive(event)
            if pending != nil, screens.isEmpty { openWindow(.newChat(slot: UUID())) }
        }
    }

    func focusWindow(presenting value: ConversationWindowValue, besides id: UUID) -> Bool {
        guard let openWindow, screens.contains(where: { $0.key != id && $0.value.presents(value) }) else { return false }
        openWindow(value)
        return true
    }

    func openMainWindow() {
        guard let mainWindowOpener else {
            return logger.error("No window has attached a window opener; the main window cannot open.")
        }
        mainWindowOpener()
    }

    private func deliverPending() {
        guard let held = pending else { return }
        guard !held.event.expires || now().timeIntervalSince(held.receivedAt) <= Self.maximumAge else {
            pending = nil
            logger.notice("Dropped expired external event.")
            return
        }
        guard let destination = destination(for: held.event) else { return }
        pending = nil
        switch destination {
        case .screen(let id):
            screens[id]?.perform(held.event)
        case .newWindow(let value):
            openWindow?(value)
        }
    }

    private enum Destination {
        case screen(UUID)
        case newWindow(ConversationWindowValue)
    }

    private func destination(for event: ExternalEvent) -> Destination? {
        if case .completionNotificationTap = event, !isNavigationReady { return nil }
        guard case .open(let value) = event else { return keyScreen.map { .screen($0) } }
        if let presenting = activeScreens.first(where: { screens[$0]?.presents(value) == true }) {
            return .screen(presenting)
        }
        if screens.count == 1, let only = screens.keys.first, activeScreens.contains(only) { return .screen(only) }
        if openWindow != nil, !activeScreens.isEmpty { return .newWindow(value) }
        return keyScreen.map { .screen($0) }
    }

    private var keyScreen: UUID? {
        keyScreenID.flatMap { screens[$0] != nil && activeScreens.contains($0) ? $0 : nil }
    }
}

extension ExternalEvent {
    init?(url: URL) {
        if let link = RemoteCoderDeepLinks.conversation(from: url) {
            self = .open(.conversation(ConversationAddress(hostID: link.hostID, threadID: link.threadID)))
        } else if let request = RemoteCoderDeepLinks.request(from: url) {
            self = .quickAction(request)
        } else if let id = RemoteCoderDeepLinks.sharedItems(from: url) {
            self = .sharedItems(id)
        } else if let id = RemoteCoderDeepLinks.voiceCall(from: url) {
            self = .presentVoiceCall(id)
        } else {
            return nil
        }
    }
}
