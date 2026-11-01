import Foundation
import Observation
import OSLog

@Observable @MainActor
final class HapticService {
    static let preferenceKey = "remoteCoder.appHapticsEnabled"
    static let strengthKey = "remoteCoder.hapticStrength"

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            if !isEnabled { cancelPlayback() }
        }
    }
    var strength: HapticStrength {
        didSet {
            guard strength != oldValue else { return }
            defaults.set(strength.rawValue, forKey: Self.strengthKey)
            cancelPlayback()
        }
    }
    @ObservationIgnored private var native: (any HapticNativePlaying)?
    @ObservationIgnored private let makeInteractionPlayer: (any HapticNativePlaying) -> any HapticInteractionPlaying
    @ObservationIgnored private let makeStreamingPlayer: () -> any HapticStreamingPlaying
    @ObservationIgnored private var streamingPlayer: (any HapticStreamingPlaying)?
    @ObservationIgnored private var lastStreamingPulse = -TimeInterval.infinity
    @ObservationIgnored private var lastFeedback: ContinuousClock.Instant?
    @ObservationIgnored private var interaction: (owner: UUID, player: any HapticInteractionPlaying)?
    @ObservationIgnored private var finishingPlayer: (owner: UUID, player: any HapticInteractionPlaying)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let supportsHaptics: Bool
    @ObservationIgnored private let isActive: () -> Bool
    @ObservationIgnored private var isCallActive: () -> Bool = { false }
    @ObservationIgnored private var captureOwners: Set<UUID> = []
    @ObservationIgnored private var occurrences: Set<HapticOccurrence> = []
    @ObservationIgnored private var occurrenceOrder: [HapticOccurrence] = []
    @ObservationIgnored let signposter = OSSignposter(subsystem: "RemoteCoder", category: "Haptics")

    init(defaults: UserDefaults, supportsHaptics: Bool,
         isActive: @escaping () -> Bool,
         makeInteractionPlayer: @escaping (any HapticNativePlaying) -> any HapticInteractionPlaying,
         makeStreamingPlayer: @escaping () -> any HapticStreamingPlaying) {
        self.defaults = defaults
        self.makeInteractionPlayer = makeInteractionPlayer
        self.makeStreamingPlayer = makeStreamingPlayer
        self.supportsHaptics = supportsHaptics
        self.isActive = isActive
        self.isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        self.strength = defaults.string(forKey: Self.strengthKey).flatMap(HapticStrength.init(rawValue:)) ?? .strong
    }

    func bindCallState(_ isCallActive: @escaping () -> Bool) {
        self.isCallActive = isCallActive
    }

    var canPlay: Bool { isAvailable && captureOwners.isEmpty }

    var canPlayStreaming: Bool {
        canPlay && interaction == nil && finishingPlayer?.player.hasActiveAccent != true
            && (lastFeedback.map { $0.duration(to: .now) >= .milliseconds(200) } ?? true)
    }

    func admitsStreamingFrame(at time: TimeInterval) -> Bool {
        time - lastStreamingPulse >= StreamingRevealSchedule.stagger - 1.0 / 240
    }

    func prepareStreaming() {
        guard canPlay else { return }
        let player = streamingPlayer ?? makeStreamingPlayer()
        streamingPlayer = player
        player.prepare { [weak self] in self?.canPlay == true }
    }

    func playStreaming(punch: Float, at time: TimeInterval) {
        guard canPlayStreaming, admitsStreamingFrame(at: time), let streamingPlayer else { return }
        lastStreamingPulse = time
        signposter.emitEvent("streaming-word-request", "punch=\(punch)")
        streamingPlayer.play(punch: punch)
    }

    private var isAvailable: Bool { isEnabled && supportsHaptics && isActive() && !isCallActive() }

    func canPlay(_ event: HapticEvent) -> Bool {
        isAvailable && (captureOwners.isEmpty || event.playsDuringCapture)
    }

    /// Suppression starts before audio activation suspends, not from an optimistic UI flag.
    func beginCapture(owner: UUID) {
        captureOwners.insert(owner)
        cancelPlayback()
    }
    func endCapture(owner: UUID) { captureOwners.remove(owner) }

    /// No delayed work, engine start, I/O or feedback queue. Ineligible events are discarded.
    func play(_ event: HapticEvent, occurrence: HapticOccurrence? = nil) {
        if let occurrence, !consume(occurrence) { return }
        guard accept(event) else { return }
        native?.play(event.recipe(for: strength))
    }

    func consume(_ occurrence: HapticOccurrence) -> Bool {
        guard occurrences.insert(occurrence).inserted else { return false }
        occurrenceOrder.append(occurrence)
        if occurrenceOrder.count > 128 { occurrences.remove(occurrenceOrder.removeFirst()) }
        return true
    }

    func attach(_ player: any HapticNativePlaying) {
        guard native !== player else { return }
        cancelPlayback()
        native = player
    }

    func detach(_ player: any HapticNativePlaying) {
        guard native === player else { return }
        cancelPlayback()
        native = nil
    }

    func beginInteraction(owner: UUID) {
        guard let native else { return }
        beginInteraction(owner: owner) { makeInteractionPlayer(native) }
    }

    func beginInteraction(owner: UUID, makePlayer: () -> any HapticInteractionPlaying) {
        guard canPlay else { return }
        guard interaction?.owner != owner else { return }
        cancelInteractions()
        let player = makePlayer()
        interaction = (owner, player)
        player.prepare(strength: strength) { [weak self] in self?.canPlay == true }
    }

    /// Gesture ticks bypass SwiftUI state coalescing, but retain the central policy.
    func playInteraction(_ event: HapticEvent, owner: UUID) {
        guard let interaction, interaction.owner == owner, accept(event) else { return }
        interaction.player.play(event)
    }

    func finishInteraction(owner: UUID) {
        guard let current = interaction, current.owner == owner else { return }
        interaction = nil
        finishingPlayer?.player.cancel()
        finishingPlayer = current
        current.player.finish()
    }

    func cancelInteraction(owner: UUID) {
        if interaction?.owner == owner {
            interaction?.player.cancel()
            interaction = nil
        }
        if finishingPlayer?.owner == owner {
            finishingPlayer?.player.cancel()
            finishingPlayer = nil
        }
    }

    private func cancelInteractions() {
        interaction?.player.cancel()
        finishingPlayer?.player.cancel()
        interaction = nil
        finishingPlayer = nil
    }

    func cancelPlayback() {
        cancelInteractions()
        native?.release()
        streamingPlayer?.cancel()
        streamingPlayer = nil
    }

    /// Standard leaves native selection alone. Strong supplements only a user write,
    /// never a restore, catalog refresh, provider normalization or remote update.
    func nativeSelectionChanged() {
        if strength == .strong { play(.selection) }
    }

    private func accept(_ event: HapticEvent) -> Bool {
        let allowed = canPlay(event)
        if allowed { lastFeedback = .now }
        signposter.emitEvent("feedback-intent", "\(event.rawValue, privacy: .public) eligible=\(allowed)")
        return allowed
    }
}
