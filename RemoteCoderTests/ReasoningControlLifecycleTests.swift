import Observation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

/// Hosts only the production control. No UI automation, gateway, audio or hardware playback.
@Suite(.serialized)
@MainActor
struct ReasoningControlLifecycleTests {
    @Test func switchingChatsAndRepeatedAdjustmentsAroundSyncStatusKeepAcceptedFeedback() async throws {
        let steps: [(newChat: Bool, savedChat: Bool, target: ReasoningEffort, ticks: Int)] = [
            (true, false, .low, 4), (true, true, .low, 4), (true, true, .low, 4),
            (false, true, .high, 4), (false, true, .medium, 2), (false, false, .high, 2),
        ]
        try await withControl { fixture, haptics, view in
            for step in steps {
                if step.newChat {
                    fixture.conversation += 1
                    fixture.reasoning = .effort(.high)
                }
                fixture.savedChat = step.savedChat
                fixture.showsStatus = false
                try await flushLayout(view)
                let button = try #require(reasoningButton(in: view))
                button.sendActions(for: .primaryActionTriggered)
                let session = try #require(fixture.picker.session)
                let player = try #require(haptics.players.last)
                session.beginDrag()
                session.select(index: try #require(session.choices.firstIndex(of: .effort(step.target))))
                player.events.removeAll()
                let originalY = button.convert(button.bounds, to: nil).minY
                fixture.picker.finish(session)
                #expect(fixture.reasoning == .effort(step.target))
                try await flushLayout(view)
                if step.savedChat {
                    #expect(button.convert(button.bounds, to: nil).minY < originalY,
                        "The sync message must actually reflow the settings row")
                }
                // The production overlay calls this at return-animation completion.
                fixture.picker.completeDismissal(of: session)
                try #require(await waitUntil { player.events.contains(.sliderStep) }, "\(step): no step feedback")
                fixture.showsStatus = false
                try await flushLayout(view)
                try #require(await waitUntil { player.finished }, "\(step): feedback never finished")
                #expect(player.events == [.sliderRelease] + Array(repeating: .sliderStep, count: step.ticks),
                    "\(step), events=\(player.events), cancelled=\(player.cancelled)")
            }
        }
    }

    @Test func layoutChangeDuringTrackingStillCancelsWithoutCommitting() async throws {
        try await withControl { fixture, haptics, view in
            try await flushLayout(view)
            let button = try #require(reasoningButton(in: view))
            button.sendActions(for: .primaryActionTriggered)
            let session = try #require(fixture.picker.session)
            let player = try #require(haptics.players.last)
            session.beginDrag()
            session.select(index: 1)
            fixture.showsStatus = true
            try await flushLayout(view)
            #expect(fixture.picker.session == nil)
            #expect(player.cancelled)
            let events = player.events
            fixture.picker.finish(session)
            fixture.picker.completeDismissal(of: session)
            #expect(fixture.reasoning == .effort(.high))
            #expect(player.events == events)
        }
    }

    @Test func switchingAwayDuringSettlementCancelsTheOldOwnerAndTheNewControlWorks() async throws {
        try await withControl { fixture, haptics, view in
            try await flushLayout(view)
            let button = try #require(reasoningButton(in: view))
            button.sendActions(for: .primaryActionTriggered)
            let session = try #require(fixture.picker.session)
            let oldPlayer = try #require(haptics.players.last)
            session.select(index: 1)
            fixture.picker.finish(session)
            try await flushLayout(view)
            fixture.picker.completeDismissal(of: session)
            try #require(await waitUntil { oldPlayer.events.filter { $0 == .sliderStep }.count >= 2 })
            fixture.conversation += 1
            fixture.reasoning = .effort(.high)
            try await flushLayout(view)
            #expect(oldPlayer.cancelled)
            let oldEvents = oldPlayer.events
            let replacement = try #require(reasoningButton(in: view))
            replacement.sendActions(for: .primaryActionTriggered)
            let newSession = try #require(fixture.picker.session)
            let newPlayer = try #require(haptics.players.last)
            #expect(newPlayer !== oldPlayer)
            newSession.select(index: 1)
            newPlayer.events.removeAll()
            fixture.picker.finish(newSession)
            try await flushLayout(view)
            fixture.picker.completeDismissal(of: newSession)
            try #require(await waitUntil { newPlayer.finished })
            #expect(newPlayer.events == Array(repeating: .sliderStep, count: 4))
            #expect(oldPlayer.events == oldEvents)
        }
    }

    @Test func automaticToTopLevelStillPlaysItsWholeAdjustment() async throws {
        try await withControl { fixture, haptics, view in
            fixture.reasoning = .automatic
            try await flushLayout(view)
            let button = try #require(reasoningButton(in: view))
            button.sendActions(for: .primaryActionTriggered)
            let session = try #require(fixture.picker.session)
            let player = try #require(haptics.players.last)
            session.select(index: try #require(session.choices.firstIndex(of: .effort(.high))))
            player.events.removeAll()
            fixture.picker.finish(session)
            try await flushLayout(view)
            fixture.picker.completeDismissal(of: session)
            try #require(await waitUntil { player.finished })
            #expect(fixture.reasoning == .effort(.high))
            #expect(player.events == Array(repeating: .sliderStep, count: 6))
        }
    }

    private func withControl(
        _ body: (ReasoningControlFixture, HapticFixture, UIView) async throws -> Void
    ) async throws {
        let haptics = HapticFixture()
        defer { haptics.cleanUp() }
        let preferences = ModelPickerPreferences(defaults: haptics.defaults)
        preferences.show(only: [.low, .medium, .high])
        let fixture = ReasoningControlFixture(haptics: haptics.service)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: ReasoningControlFixtureView(fixture: fixture)
            .environment(AppThemeStore())
            .environment(preferences)
            .environment(\.scenePhase, .active)
            .defaultAppStorage(haptics.defaults))
        hosted.show(controller)
        defer { hosted.close() }
        fixture.picker.updateViewport(CGRect(x: 0, y: 0, width: 390, height: 844))
        try await body(fixture, haptics, controller.view)
    }

    private func reasoningButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           button.accessibilityIdentifier == "conversation-reasoning-control" { return button }
        for child in view.subviews {
            if let button = reasoningButton(in: child) { return button }
        }
        return nil
    }

    private func flushLayout(_ view: UIView) async throws {
        for _ in 0..<6 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Observable @MainActor
private final class ReasoningControlFixture {
    let haptics: HapticService
    let picker: ReasoningPickerPresentation
    let model = ModelOption(id: "fixture-model", displayName: "Fixture", reasoningEfforts: [.low, .medium, .high],
        supportsFastMode: true, supportsDaybreakBlue: false, acceptsImages: true, provider: .codex, isListed: true)
    var conversation = 0
    var reasoning: ReasoningSelection = .effort(.high)
    var savedChat = false
    var showsStatus = false

    init(haptics: HapticService) {
        self.haptics = haptics
        picker = ReasoningPickerPresentation { event, owner in
            haptics.playInteraction(event, owner: owner)
        }
    }
}

private struct ReasoningControlFixtureView: View {
    let fixture: ReasoningControlFixture

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                ConversationSettingsControls(models: [fixture.model], model: .constant(fixture.model),
                    reasoning: Binding(get: { fixture.reasoning }, set: {
                        fixture.reasoning = $0
                        fixture.showsStatus = fixture.savedChat
                    }), fastMode: .constant(false), haptics: fixture.haptics) { EmptyView() }
                    .id(fixture.conversation)
                if fixture.showsStatus {
                    Text("Applying settings…").font(.caption)
                }
                Text("Composer").frame(height: 80)
            }
            .padding(8)
        }
        .frame(width: 390, height: 844)
        .environment(fixture.picker)
    }
}
