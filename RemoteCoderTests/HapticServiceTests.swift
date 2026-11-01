import CoreHaptics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
struct HapticServiceTests {
    @Test func selectionInteractionsUseOnlyTheirViewAttachedGeneratorAndReleaseIt() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let owner = UUID()
        let view = UIView()
        fixture.service.beginSelectionInteraction(owner: owner, in: view)
        #expect(fixture.players.isEmpty)
        let generator = try #require(view.interactions.compactMap { $0 as? UISelectionFeedbackGenerator }.first)
        #expect(generator.view === view)
        fixture.service.playInteraction(.selection, owner: owner)
        #expect(fixture.service.pulse == nil)
        fixture.service.finishInteraction(owner: owner)
        #expect(generator.view == nil)
        #expect(view.interactions.compactMap { $0 as? UISelectionFeedbackGenerator }.isEmpty)
        fixture.service.playInteraction(.selection, owner: owner)
        #expect(fixture.service.pulse == nil)
    }

    @Test func streamingTicksCoalesceAcrossHostsWithoutLosingJitteredFramesOrSemanticOccurrences() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let occurrence = HapticOccurrence(hostID: UUID(), kind: .question, id: "question")
        #expect(fixture.service.consume(occurrence))
        fixture.service.prepareStreaming()
        let player = try #require(fixture.streamingPlayers.first)
        for time in [10, 10, 10.03332, 10.05, 10.06664, 10.13336] {
            fixture.service.playStreaming(punch: 1, at: time)
        }
        #expect(player.punches == [1, 1, 1])
        for index in 1...200 { fixture.service.playStreaming(punch: 0.2, at: 11 + Double(index) * 0.07) }
        #expect(!fixture.service.consume(occurrence))
        #expect(fixture.service.pulse == nil)
    }

    @Test func streamingYieldsToGesturesFinishingAccentsAndAcceptedFeedback() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.service.prepareStreaming()
        let stream = try #require(fixture.streamingPlayers.first)
        let owner = UUID()
        fixture.service.beginInteraction(owner: owner)
        #expect(!fixture.service.canPlayStreaming)
        #expect(stream.isEligible())
        fixture.service.playStreaming(punch: 1, at: 10)
        #expect(stream.punches.isEmpty)
        let gesture = try #require(fixture.players.first)
        gesture.hasActiveAccent = true
        fixture.service.finishInteraction(owner: owner)
        #expect(!fixture.service.canPlayStreaming)
        gesture.hasActiveAccent = false
        #expect(fixture.service.canPlayStreaming)
        fixture.service.play(.buttonPress)
        #expect(!stream.cancelled)
        #expect(!fixture.service.canPlayStreaming)
        fixture.service.playStreaming(punch: 1, at: 10)
        #expect(stream.punches.isEmpty)
    }

    @Test func streamingPolicyCancelsCaptureOptOutAndScenePlayback() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.service.prepareStreaming()
        let first = try #require(fixture.streamingPlayers.last)
        let capture = UUID()
        fixture.service.beginCapture(owner: capture)
        #expect(first.cancelled)
        #expect(!first.isEligible())
        fixture.service.endCapture(owner: capture)
        fixture.service.prepareStreaming()
        let second = try #require(fixture.streamingPlayers.last)
        fixture.callActive = true
        #expect(!second.isEligible())
        fixture.service.playStreaming(punch: 1, at: 10)
        #expect(second.punches.isEmpty)
        fixture.service.cancelPlayback()
        fixture.callActive = false
        fixture.service.prepareStreaming()
        let third = try #require(fixture.streamingPlayers.last)
        fixture.service.isEnabled = false
        #expect(third.cancelled)
        fixture.service.isEnabled = true
        fixture.active = false
        fixture.service.prepareStreaming()
        #expect(fixture.streamingPlayers.count == 3)
    }

    @Test func streamingPatternExportsTheWordTransientRecipe() throws {
        for punch in [Float(1), 0.2] {
            let pattern = try PreparedStreamingHapticPlayer.pattern(punch: punch)
            let exported = try pattern.exportDictionary()
            let entries = try #require(exported[.pattern] as? [[String: Any]])
            #expect(entries.count == 1)
            let event = try #require(entries.first?[CHHapticPattern.Key.event.rawValue] as? [String: Any])
            #expect(event[CHHapticPattern.Key.eventType.rawValue] as? String == CHHapticEvent.EventType.hapticTransient.rawValue)
            #expect(event[CHHapticPattern.Key.time.rawValue] as? Double == 0)
            let parameters = try #require(event[CHHapticPattern.Key.eventParameters.rawValue] as? [[String: Any]])
            let values = Dictionary(uniqueKeysWithValues: try parameters.map { parameter in
                (try #require(parameter[CHHapticPattern.Key.parameterID.rawValue] as? String),
                 try #require(parameter[CHHapticPattern.Key.parameterValue.rawValue] as? Float))
            })
            #expect(values[CHHapticEvent.ParameterID.hapticIntensity.rawValue].map { abs($0 - 0.9 * punch) < 0.00001 } == true)
            let sharpness = try #require(values[CHHapticEvent.ParameterID.hapticSharpness.rawValue])
            #expect(sharpness >= 0.2 + 0.1 * punch && sharpness <= 0.4 + 0.1 * punch)
        }
    }

    @Test func preferencePersistsAndNeverReplaysSuppressedFeedback() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.service.isEnabled)
        fixture.service.isEnabled = false
        fixture.service.play(.commit)
        #expect(fixture.service.pulse == nil)
        #expect(!fixture.makeService().isEnabled)
        fixture.service.isEnabled = true
        #expect(fixture.service.pulse == nil)
        fixture.service.play(.commit)
        #expect(fixture.service.pulse?.event == .commit)
    }

    @Test func audioOwnersAreIndependentAndCallsSuppressEveryAppSurface() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let first = UUID(), second = UUID()
        fixture.service.beginCapture(owner: first)
        fixture.service.beginCapture(owner: second)
        fixture.service.endCapture(owner: first)
        #expect(fixture.service.feedbackForInteraction(.iconPress) == nil)
        fixture.service.endCapture(owner: second)
        #expect(fixture.service.feedbackForInteraction(.iconPress) != nil)
        fixture.callActive = true
        #expect(fixture.service.feedbackForInteraction(.toggleOn) == nil)
        fixture.callActive = false
        #expect(fixture.service.canPlay)
    }

    @Test func inactiveAndUnsupportedDevicesDoNotPublish() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.active = false
        fixture.service.play(.success)
        #expect(fixture.service.pulse == nil)
        fixture.active = true
        #expect(fixture.service.pulse == nil)
        let unsupported = fixture.makeService(supportsHaptics: false)
        unsupported.play(.error)
        #expect(unsupported.pulse == nil)
        #expect(unsupported.feedbackForInteraction(.buttonPress) == nil)
    }

    @Test func occurrencesAreHostQualifiedAndConsumedEvenWhenDisabled() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let first = HapticOccurrence(hostID: UUID(), kind: .question, id: "same-thread|same-item")
        fixture.service.isEnabled = false
        fixture.service.play(.warning, occurrence: first)
        fixture.service.isEnabled = true
        fixture.service.play(.warning, occurrence: first)
        #expect(fixture.service.pulse == nil)
        let second = HapticOccurrence(hostID: UUID(), kind: .question, id: first.id)
        fixture.service.play(.warning, occurrence: second)
        let delivered = fixture.service.pulse?.id
        fixture.service.play(.warning, occurrence: second)
        #expect(fixture.service.pulse?.id == delivered)
    }

    @Test func identicalLocalActionsStayDistinctWithoutATimerCooldown() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.service.play(.copied)
        let first = fixture.service.pulse?.id
        fixture.service.play(.copied)
        #expect(fixture.service.pulse?.id != first)
        fixture.service.play(.error)
        let failure = fixture.service.pulse?.id
        fixture.service.play(.error)
        #expect(fixture.service.pulse?.id != failure)
    }

    @Test func staleAndNowIneligiblePulsesAreDiscardedAtOutput() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let stale = HapticPulse(event: .commit, strength: .strong, requestedAt: ContinuousClock.now.advanced(by: .seconds(-1)))
        #expect(fixture.service.feedback(for: stale) == nil)
        let current = HapticPulse(event: .commit, strength: .strong, requestedAt: .now)
        #expect(fixture.service.feedback(for: current) != nil)
        fixture.callActive = true
        #expect(fixture.service.feedback(for: current) == nil)
    }

    @Test func strengthDefaultsToStrongPersistsAndNeverReenablesAnOptOut() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: HapticService.preferenceKey)
        #expect(fixture.service.strength == .strong)
        #expect(!fixture.service.isEnabled)
        fixture.service.strength = .standard
        #expect(fixture.makeService().strength == .standard)
        #expect(!fixture.makeService().isEnabled)
    }

    @Test func changingStrengthInvalidatesAPendingPulseAndPreparedGesture() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let owner = UUID()
        fixture.service.play(.commit)
        let oldPulse = try #require(fixture.service.pulse)
        fixture.service.beginInteraction(owner: owner)
        let player = try #require(fixture.players.last)
        fixture.service.strength = .standard
        #expect(player.cancelled)
        #expect(fixture.service.pulse == nil)
        #expect(fixture.service.feedback(for: oldPulse) == nil)
        fixture.service.playInteraction(.sliderStep, owner: owner)
        #expect(player.events.isEmpty)
    }

    @Test func preparedGesturesHaveOneOwnerAndDoNotCoalesceSynchronousTicks() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let first = UUID(), second = UUID()
        fixture.service.beginInteraction(owner: first)
        fixture.service.beginInteraction(owner: first)
        #expect(fixture.players.count == 1)
        let firstPlayer = try #require(fixture.players.last)
        fixture.service.playInteraction(.sliderStep, owner: first)
        fixture.service.playInteraction(.sliderMaximum, owner: first)
        #expect(firstPlayer.events == [.sliderStep, .sliderMaximum])
        #expect(fixture.service.pulse == nil)
        fixture.service.beginInteraction(owner: second)
        #expect(firstPlayer.cancelled)
        let secondPlayer = try #require(fixture.players.last)
        fixture.service.playInteraction(.sliderRelease, owner: first)
        fixture.service.cancelInteraction(owner: first)
        #expect(secondPlayer.events.isEmpty)
        #expect(!secondPlayer.cancelled)
        fixture.service.playInteraction(.lift, owner: second)
        #expect(secondPlayer.events == [.lift])
    }

    @Test func captureAndOptOutAlsoCancelAFinishingAccent() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let owner = UUID(), capture = UUID()
        fixture.service.beginInteraction(owner: owner)
        let player = try #require(fixture.players.last)
        fixture.service.playInteraction(.sliderSettle, owner: owner)
        fixture.service.finishInteraction(owner: owner)
        #expect(player.finished)
        fixture.service.beginCapture(owner: capture)
        #expect(player.cancelled)
        #expect(!player.isEligible())
        fixture.service.endCapture(owner: capture)
        fixture.service.playInteraction(.sliderStep, owner: owner)
        #expect(player.events == [.sliderSettle])
        fixture.service.beginInteraction(owner: owner)
        let replacement = try #require(fixture.players.last)
        fixture.service.isEnabled = false
        #expect(replacement.cancelled)
    }

    @Test func callsAndInactiveScenesRejectPreparedPlaybackWithoutReplaying() throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let owner = UUID()
        fixture.active = false
        fixture.service.beginInteraction(owner: owner)
        #expect(fixture.players.isEmpty)
        fixture.active = true
        fixture.service.beginInteraction(owner: owner)
        let player = try #require(fixture.players.last)
        fixture.callActive = true
        #expect(!player.isEligible())
        fixture.service.playInteraction(.lift, owner: owner)
        fixture.service.cancelPlayback()
        fixture.callActive = false
        fixture.service.playInteraction(.lift, owner: owner)
        #expect(player.events.isEmpty)
    }

    @Test func nativeFeedbackOnlyFollowsAcceptedUserChangesAndPreservesTransactions() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        var value = 0
        var receivedAnimation: Animation?
        let original = Binding(get: { value }, set: { new, transaction in
            if new < 10 { value = new }
            receivedAnimation = transaction.animation
        })
        let input = original.nativeSelectionFeedback(using: fixture.service)
        value = 2 // Programmatic restoration never goes through the input binding.
        #expect(fixture.service.pulse == nil)
        input.wrappedValue = 2
        #expect(fixture.service.pulse == nil)
        input.transaction(Transaction(animation: .linear)).wrappedValue = 3
        #expect(receivedAnimation == .linear)
        #expect(fixture.service.pulse?.event == .selection)
        let accepted = fixture.service.pulse?.id
        input.wrappedValue = 99
        #expect(value == 3)
        #expect(fixture.service.pulse?.id == accepted)
        fixture.service.strength = .standard
        input.wrappedValue = 4
        #expect(value == 4)
        #expect(fixture.service.pulse == nil)
        fixture.service.isEnabled = false
        fixture.service.strength = .strong
        input.wrappedValue = 5
        #expect(value == 5)
        #expect(fixture.service.pulse == nil)
    }

    @Test func strongerRecipesRetainSemanticHierarchyAndNotificationPatterns() {
        for event in HapticEvent.allCases {
            if case let .impact(_, intensity) = event.recipe(for: .strong) {
                #expect((0...1).contains(intensity))
            }
            #expect(event.accent(for: .standard) == nil)
        }
        #expect(impactWeight(HapticEvent.commit.recipe(for: .strong)) == .medium)
        #expect(HapticEvent.sliderStep.recipe(for: .standard) == .selection)
        #expect(impactWeight(HapticEvent.sliderStep.recipe(for: .strong)) == .rigid)
        #expect(HapticEvent.selection.recipe(for: .strong) == .selection)
        for event in [HapticEvent.success, .warning, .error] {
            #expect(event.recipe(for: .strong) == event.recipe(for: .standard))
            #expect(event.accent(for: .strong) == nil)
        }
        #expect(HapticEvent.lift.accent(for: .strong) == .lift)
        #expect(HapticEvent.sliderSettle.accent(for: .strong) == .seat)
        #expect(HapticEvent.commit.accent(for: .strong) == nil)
    }

    @Test func customAccentsAreShortAndConstructWithoutHardwarePlayback() throws {
        for accent in HapticAccent.allCases {
            let pattern = try accent.makePattern()
            #expect(pattern.duration > 0)
            #expect(pattern.duration <= 0.1)
        }
    }

    @Test(arguments: HapticStrength.allCases)
    func recipesUseIPhonePlaybackRatherThanVisionOnlyPatterns(strength: HapticStrength) {
        #expect(impactWeight(HapticEvent.buttonPress.recipe(for: strength)) == .light)
        #expect(impactWeight(HapticEvent.iconPress.recipe(for: strength)) == .light)
        for event in HapticEvent.allCases {
            let feedback = event.recipe(for: strength).feedback
            #expect(feedback != .press(.button))
            #expect(feedback != .press(.buttonIconOnly))
            #expect(feedback != .press(.slider))
            #expect(feedback != .release(.slider))
            #expect(feedback != .selection(.on))
            #expect(feedback != .selection(.off))
            #expect(feedback != .selection(.minimum))
            #expect(feedback != .selection(.maximum))
        }
    }

    private func impactWeight(_ recipe: HapticRecipe) -> HapticRecipe.Impact? {
        guard case let .impact(weight, _) = recipe else { return nil }
        return weight
    }
}

