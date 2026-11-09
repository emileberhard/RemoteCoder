import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct HapticServiceTests {
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
        #expect(fixture.native.events.isEmpty)
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
        fixture.active = false
        fixture.service.prepareStreaming()
        #expect(fixture.streamingPlayers.count == 3)
    }

    @Test func audioOwnersAreIndependentAndCallsSuppressEveryAppSurface() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let first = UUID(), second = UUID()
        fixture.service.beginCapture(owner: first)
        fixture.service.beginCapture(owner: second)
        fixture.service.endCapture(owner: first)
        fixture.service.play(.iconPress)
        #expect(fixture.native.events.isEmpty)
        fixture.service.endCapture(owner: second)
        fixture.service.play(.iconPress)
        #expect(fixture.native.events == [HapticEvent.iconPress.recipe])
        fixture.callActive = true
        fixture.service.play(.toggleOn)
        #expect(fixture.native.events == [HapticEvent.iconPress.recipe])
        fixture.callActive = false
        #expect(fixture.service.canPlay)
    }

    @Test func inactiveAndUnsupportedDevicesDoNotPlay() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.active = false
        fixture.service.play(.success)
        #expect(fixture.native.events.isEmpty)
        fixture.active = true
        #expect(fixture.native.events.isEmpty)
        let unsupported = fixture.makeService(supportsHaptics: false)
        unsupported.play(.error)
        unsupported.play(.buttonPress)
        #expect(fixture.native.events.isEmpty)
    }

    @Test func occurrencesAreHostQualifiedAndConsumedEvenWhenSuppressed() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let first = HapticOccurrence(hostID: UUID(), kind: .question, id: "same-thread|same-item")
        fixture.active = false
        fixture.service.play(.warning, occurrence: first)
        fixture.active = true
        fixture.service.play(.warning, occurrence: first)
        #expect(fixture.native.events.isEmpty)
        let second = HapticOccurrence(hostID: UUID(), kind: .question, id: first.id)
        fixture.service.play(.warning, occurrence: second)
        let delivered = fixture.native.events.count
        fixture.service.play(.warning, occurrence: second)
        #expect(fixture.native.events.count == delivered)
    }

    @Test func identicalLocalActionsSubmitInOrderBeforeReturning() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        fixture.service.play(.copied)
        #expect(fixture.native.events == [HapticEvent.copied.recipe])
        fixture.service.play(.copied)
        fixture.service.play(.error)
        fixture.service.play(.error)
        #expect(fixture.native.events == [HapticEvent.copied, .copied, .error, .error].map { $0.recipe })
    }

    @Test func replacingAttachmentReleasesOldResourcesAndLateDetachCannotRemoveTheReplacement() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let service = fixture.service
        let oldReleases = fixture.native.releases
        let replacement = RecordingNativeHapticPlayer()
        service.attach(replacement)
        #expect(fixture.native.releases == oldReleases + 1)
        service.detach(fixture.native)
        service.play(.commit)
        service.play(.copied)
        #expect(replacement.events == [HapticEvent.commit.recipe, HapticEvent.copied.recipe])
        #expect(replacement.releases == 0)
        service.detach(replacement)
        #expect(replacement.releases == 1)
        let occurrence = HapticOccurrence(hostID: UUID(), kind: .question, id: "detached")
        service.play(.warning, occurrence: occurrence)
        service.attach(replacement)
        service.play(.warning, occurrence: occurrence)
        #expect(replacement.events.count == 2)
    }

    @Test func captureAllowsOnlyRefusalAndNeverReplaysOtherEvents() {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let owner = UUID()
        fixture.service.beginCapture(owner: owner)
        fixture.service.play(.commit)
        fixture.service.play(.refused)
        #expect(fixture.native.events == [.error])
        fixture.service.endCapture(owner: owner)
        #expect(fixture.native.events == [.error])
        fixture.service.play(.commit)
        #expect(fixture.native.events.last == HapticEvent.commit.recipe)
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
        #expect(fixture.native.events.isEmpty)
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

    @Test func captureAlsoCancelsAFinishingAccent() throws {
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

    @Test func impactIntensitiesStayWithinTheGeneratorRange() {
        for event in HapticEvent.allCases {
            if case let .impact(_, intensity) = event.recipe {
                #expect((0...1).contains(intensity))
            }
        }
    }
}

@MainActor
private final class HapticFixture {
    var active = true
    var callActive = false
    let native = RecordingNativeHapticPlayer()
    var players: [RecordingHapticPlayer] = []
    var streamingPlayers: [RecordingStreamingHapticPlayer] = []
    lazy var service = makeService()

    func makeService(supportsHaptics: Bool = true) -> HapticService {
        let service = HapticService(supportsHaptics: supportsHaptics,
                                    isActive: { [weak self] in self?.active == true },
                                    makeInteractionPlayer: { [weak self] _ in
                                        let player = RecordingHapticPlayer()
                                        self?.players.append(player)
                                        return player
                                    }, makeStreamingPlayer: { [weak self] in
                                        let player = RecordingStreamingHapticPlayer()
                                        self?.streamingPlayers.append(player)
                                        return player
                                    })
        service.attach(native)
        service.bindCallState { [weak self] in self?.callActive == true }
        return service
    }

    func cleanUp() {
        service.cancelPlayback()
    }
}

@MainActor
private final class RecordingHapticPlayer: HapticInteractionPlaying {
    var hasActiveAccent = false
    var events: [HapticEvent] = []
    var finished = false
    var cancelled = false
    var isEligible: @MainActor () -> Bool = { false }

    func prepare(canPlay: @escaping @MainActor () -> Bool) { isEligible = canPlay }
    func play(_ event: HapticEvent) { events.append(event) }
    func finish() { finished = true }
    func cancel() { cancelled = true; hasActiveAccent = false }
}

@MainActor
private final class RecordingStreamingHapticPlayer: HapticStreamingPlaying {
    var punches: [Float] = []
    var cancelled = false
    var isEligible: @MainActor () -> Bool = { false }

    func prepare(canPlay: @escaping @MainActor () -> Bool) { isEligible = canPlay }
    func play(punch: Float) { punches.append(punch) }
    func cancel() { cancelled = true }
}

@MainActor
private final class RecordingNativeHapticPlayer: HapticNativePlaying {
    var events: [HapticRecipe] = []
    var releases = 0

    func prepare(_ recipe: HapticRecipe) {}
    func play(_ event: HapticEvent) { events.append(event.recipe) }
    func release() { releases += 1 }
}
