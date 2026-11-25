import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ExternalEventRouterTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    @MainActor private final class Window {
        let id = UUID()
        var performed: [ExternalEvent] = []

        func register(in router: ExternalEventRouter) {
            router.register(id: id) { [unowned self] in self.performed.append($0) }
        }
    }

    private let clock = Clock()
    private let address = ConversationAddress(hostID: UUID(), threadID: "thread-1")

    private func router() -> ExternalEventRouter {
        ExternalEventRouter(now: { [clock] in clock.now })
    }

    private var voice: ExternalEvent {
        .quickAction(RemoteCoderQuickActionRequest(
            action: .voiceChat,
            startsFreshVoiceChat: true,
            voiceConfiguration: RemoteCoderVoiceConfiguration(
                modelID: "gpt-5.6-sol", reasoningSelectionID: "effort-xhigh", fastModeEnabled: true)))
    }

    private let newChat = ExternalEvent.quickAction(RemoteCoderQuickActionRequest(action: .newChat))

    @Test func aQuickActionCarriesItsWholeConfigurationToTheActiveScreenExactlyOnce() {
        let router = router()
        let window = Window()
        window.register(in: router)
        router.setActive(true, screen: window.id)

        router.receive(voice)
        router.setActive(false, screen: window.id)
        router.setActive(true, screen: window.id)

        #expect(window.performed == [voice])
    }

    @Test func anEventReceivedBeforeAnyScreenIsActiveWaitsForIt() {
        let router = router()
        let window = Window()
        router.receive(newChat)
        window.register(in: router)
        #expect(window.performed.isEmpty)

        router.setActive(true, screen: window.id)

        #expect(window.performed == [newChat])
    }

    @Test func aNewerEventReplacesAPendingOneAndAnExpiredOneIsDropped() {
        let router = router()
        let window = Window()
        window.register(in: router)
        router.receive(voice)
        router.receive(newChat)
        router.setActive(true, screen: window.id)
        #expect(window.performed == [newChat])

        router.setActive(false, screen: window.id)
        router.receive(voice)
        clock.now.addTimeInterval(ExternalEventRouter.maximumAge + 1)
        router.setActive(true, screen: window.id)
        #expect(window.performed == [newChat])
    }

    @Test func summoningOpensTheMainWindowAndDeliversTheLatestEvent() {
        let router = router()
        #expect(!router.openMainWindow())
        var mainWindowOpens = 0
        router.attach(openMainWindow: { mainWindowOpens += 1 })
        #expect(router.openMainWindow())
        #expect(mainWindowOpens == 1)

        router.summon(.openConversation(address))
        router.summon(newChat)

        #expect(mainWindowOpens == 3)

        let window = Window()
        window.register(in: router)
        router.setKey(screen: window.id)
        #expect(window.performed == [newChat])

        router.summon(.openConversation(address))
        #expect(mainWindowOpens == 4)
        #expect(window.performed == [newChat, .openConversation(address)])
    }

    @Test func receivingAConversationEventDeliversToTheOpenWindowWithoutOpeningAnother() {
        let router = router()
        let window = Window()
        var mainWindowOpens = 0
        router.attach(openMainWindow: { mainWindowOpens += 1 })
        window.register(in: router)
        router.setActive(true, screen: window.id)

        let opening = ConversationSearchOpening(itemKey: "key", findTerm: nil)
        router.receive(.openConversation(address, opening: opening))

        #expect(window.performed == [.openConversation(address, opening: opening)])
        #expect(mainWindowOpens == 0)
    }

    @Test func anUnregisteredKeySurfaceStillDeliversEventsToTheMainWindowAndRestoresKeyOnClose() {
        let router = router()
        let main = Window()
        let quickEntryID = UUID()
        main.register(in: router)
        router.setOpen(screen: main.id)
        router.setKey(screen: quickEntryID)
        #expect(router.keyScreenID == quickEntryID)

        router.receive(.openConversation(address))
        #expect(main.performed == [.openConversation(address)])

        router.unregister(id: quickEntryID)
        router.setActive(false, screen: quickEntryID)
        #expect(router.keyScreenID == main.id)
    }

    @Test func aNotificationTapWaitsForNavigationAndNeverExpires() {
        let router = router()
        let window = Window()
        let tap = ExternalEvent.completionNotificationTap(payloadJSON: "{}")
        window.register(in: router)
        router.setActive(true, screen: window.id)

        router.receive(tap)
        clock.now.addTimeInterval(ExternalEventRouter.maximumAge + 1)
        #expect(router.hasPendingCompletionTap)
        #expect(window.performed.isEmpty)

        router.setNavigationReady()

        #expect(window.performed == [tap])
        #expect(!router.hasPendingCompletionTap)
    }
}
