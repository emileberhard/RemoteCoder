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
        var presented: Set<ConversationWindowValue> = []
        var performed: [ExternalEvent] = []

        var screen: ExternalEventRouter.Screen {
            .init(presents: { [unowned self] in self.presented.contains($0) },
                  perform: { [unowned self] in self.performed.append($0) })
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
        router.register(window.screen, id: window.id)
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
        router.register(window.screen, id: window.id)
        #expect(window.performed.isEmpty)

        router.setActive(true, screen: window.id)

        #expect(window.performed == [newChat])
    }

    @Test func aNewerEventReplacesAPendingOneAndAnExpiredOneIsDropped() {
        let router = router()
        let window = Window()
        router.register(window.screen, id: window.id)
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

    @Test func summoningWithNoWindowOpenOpensOneForTheEvent() {
        let router = router()
        var opened: [ConversationWindowValue] = []
        router.attach(openWindow: { opened.append($0) })
        let conversation = ConversationWindowValue.conversation(address)

        router.summon(.open(conversation))
        router.summon(newChat)

        #expect(opened.count == 2)
        #expect(opened.first == conversation)
        guard case .newChat = opened.last else { Issue.record("expected a new-chat window"); return }

        let window = Window()
        router.register(window.screen, id: window.id)
        router.setKey(screen: window.id)
        #expect(window.performed == [newChat])

        router.summon(.open(.newChat(slot: window.id)))
        #expect(opened.count == 3)
        #expect(window.performed == [newChat])
    }

    @Test func anOpenedMacWindowKeepsTheFocusedWindowKey() {
        let router = router()
        let focused = Window()
        let restored = Window()
        router.register(focused.screen, id: focused.id)
        router.register(restored.screen, id: restored.id)
        router.setKey(screen: focused.id)
        router.setOpen(screen: restored.id)

        router.receive(newChat)
        #expect(focused.performed == [newChat])
        #expect(restored.performed.isEmpty)

        router.setKey(screen: restored.id)
        router.receive(newChat)
        #expect(restored.performed == [newChat])
    }

    @Test func aQuickActionGoesToTheKeyScreen() {
        let router = router()
        let first = Window()
        let second = Window()
        for window in [first, second] {
            router.register(window.screen, id: window.id)
            router.setActive(true, screen: window.id)
        }

        router.receive(newChat)

        #expect(first.performed.isEmpty)
        #expect(second.performed == [newChat])
    }

    @Test func aNotificationTapWaitsForNavigationAndNeverExpires() {
        let router = router()
        let window = Window()
        let tap = ExternalEvent.completionNotificationTap(payloadJSON: "{}")
        router.register(window.screen, id: window.id)
        router.setActive(true, screen: window.id)

        router.receive(tap)
        clock.now.addTimeInterval(ExternalEventRouter.maximumAge + 1)
        #expect(router.hasPendingCompletionTap)
        #expect(window.performed.isEmpty)

        router.setNavigationReady()

        #expect(window.performed == [tap])
        #expect(!router.hasPendingCompletionTap)
    }

    @Test func openingAnAddressFocusesTheScreenPresentingIt() {
        let router = router()
        let presenting = Window()
        let key = Window()
        presenting.presented = [.conversation(address)]
        for window in [presenting, key] {
            router.register(window.screen, id: window.id)
            router.setActive(true, screen: window.id)
        }

        router.receive(.open(.conversation(address)))

        #expect(presenting.performed == [.open(.conversation(address))])
        #expect(key.performed.isEmpty)
    }

    @Test func theOnlyScreenNavigatesEvenWhenWindowsCanBeOpened() {
        let router = router()
        let only = Window()
        var opened: [ConversationWindowValue] = []
        router.attach(openWindow: { opened.append($0) })
        router.register(only.screen, id: only.id)
        router.setActive(true, screen: only.id)

        router.receive(.open(.conversation(address)))

        #expect(only.performed == [.open(.conversation(address))])
        #expect(opened.isEmpty)
    }

    @Test func anUnpresentedAddressOpensAWindowWhenSeveralScreensExist() {
        let router = router()
        let first = Window()
        let second = Window()
        var opened: [ConversationWindowValue] = []
        router.attach(openWindow: { opened.append($0) })
        for window in [first, second] {
            router.register(window.screen, id: window.id)
            router.setActive(true, screen: window.id)
        }

        router.receive(.open(.conversation(address)))

        #expect(opened == [.conversation(address)])
        #expect(first.performed.isEmpty && second.performed.isEmpty)
    }
}
