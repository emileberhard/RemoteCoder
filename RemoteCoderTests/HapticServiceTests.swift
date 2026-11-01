import CoreHaptics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
struct HapticServiceTests {
    @Test func nativePoolIsBoundedReusesGeneratorsAndDetachesOnRelease() {
        let view = UIView()
        let player = ViewHapticPlayer(view: view)
        for _ in 0..<3 {
            for strength in HapticStrength.allCases {
                for event in HapticEvent.allCases { player.prepare(event.recipe(for: strength)) }
            }
            #expect(view.interactions.count == 6)
        }
        player.release()
        #expect(view.interactions.isEmpty)
        player.prepare(.selection)
        #expect(view.interactions.count == 1)
        player.release()
        #expect(view.interactions.isEmpty)
    }

    @Test func attachmentUsesItsWindowAndOldRemovalCannotDetachNewOutput() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let first = HapticAttachment.AttachmentView(service: fixture.service)
        window.addSubview(first)
        fixture.service.play(.copied)
        #expect(window.interactions.compactMap { $0 as? UIImpactFeedbackGenerator }.count == 1)
        let second = HapticAttachment.AttachmentView(service: fixture.service)
        window.addSubview(second)
        #expect(window.interactions.isEmpty)
        first.removeFromSuperview()
        fixture.service.play(.selection)
        #expect(window.interactions.compactMap { $0 as? UISelectionFeedbackGenerator }.count == 1)
        second.removeFromSuperview()
        #expect(window.interactions.isEmpty)
        fixture.service.play(.selection)
        #expect(window.interactions.isEmpty)
    }

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
        #expect(fixture.native.events.isEmpty)
        fixture.service.finishInteraction(owner: owner)
        #expect(generator.view == nil)
        #expect(view.interactions.compactMap { $0 as? UISelectionFeedbackGenerator }.isEmpty)
        fixture.service.playInteraction(.selection, owner: owner)
        #expect(fixture.native.events.isEmpty)
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

    @Test func customAccentsAreShortAndConstructWithoutHardwarePlayback() throws {
        for accent in HapticAccent.allCases {
            let pattern = try accent.makePattern()
            #expect(pattern.duration > 0)
            #expect(pattern.duration <= 0.1)
        }
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
        #expect(fixture.native.events.isEmpty)
        input.wrappedValue = 2
        #expect(fixture.native.events.isEmpty)
        input.transaction(Transaction(animation: .linear)).wrappedValue = 3
        #expect(receivedAnimation == .linear)
        #expect(fixture.native.events.last == HapticRecipe.selection)
        let accepted = fixture.native.events.count
        input.wrappedValue = 99
        #expect(value == 3)
        #expect(fixture.native.events.count == accepted)
        fixture.service.strength = .standard
        input.wrappedValue = 4
        #expect(value == 4)
        #expect(fixture.native.events.count == accepted)
        fixture.service.isEnabled = false
        fixture.service.strength = .strong
        input.wrappedValue = 5
        #expect(value == 5)
        #expect(fixture.native.events.count == accepted)
    }
}
