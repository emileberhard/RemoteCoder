import Foundation
import Observation
import OSLog

enum ExternalEvent: Equatable, Sendable {
    case quickAction(RemoteCoderQuickActionRequest)
    case presentVoiceCall(UUID)
    case openConversation(ConversationAddress, opening: ConversationSearchOpening? = nil)
    case sharedItems(UUID)
    case completionNotificationTap(payloadJSON: String)

    var expires: Bool {
        if case .completionNotificationTap = self { return false }
        return true
    }
}

@MainActor
@Observable
final class ExternalEventRouter {
    private struct Pending {
        let event: ExternalEvent
        let receivedAt: Date
    }

    static let maximumAge: TimeInterval = 60

    @ObservationIgnored private var screens: [UUID: @MainActor (ExternalEvent) -> Void] = [:]
    @ObservationIgnored private var activeScreens: Set<UUID> = []
    private(set) var keyScreenID: UUID?
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var isNavigationReady = false
    @ObservationIgnored private var mainWindowOpener: (@MainActor () -> Void)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let logger = AppLogger(category: "ExternalEvents")

    init(now: @escaping @MainActor () -> Date) {
        self.now = now
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

    func register(id: UUID, perform: @escaping @MainActor (ExternalEvent) -> Void) {
        screens[id] = perform
        deliverPending()
    }

    func unregister(id: UUID) {
        screens[id] = nil
        activeScreens.remove(id)
        if keyScreenID == id {
            keyScreenID = activeScreens.first
            deliverPending()
        }
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
        receive(event)
        if let mainWindowOpener {
            mainWindowOpener()
        } else if screens.isEmpty {
            logger.error("No window has attached a window opener; the main window cannot open.")
        }
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
        if case .completionNotificationTap = held.event, !isNavigationReady { return }
        guard let id = keyScreen else { return }
        pending = nil
        screens[id]?(held.event)
    }

    private var keyScreen: UUID? {
        if let keyScreenID, screens[keyScreenID] != nil, activeScreens.contains(keyScreenID) {
            return keyScreenID
        }
        return activeScreens.first { screens[$0] != nil }
    }
}

extension ExternalEvent {
    init?(url: URL) {
        if let link = RemoteCoderDeepLinks.conversation(from: url) {
            self = .openConversation(ConversationAddress(hostID: link.hostID, threadID: link.threadID),
                                     opening: link.itemKey.map { ConversationSearchOpening(itemKey: $0, findTerm: nil) })
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
