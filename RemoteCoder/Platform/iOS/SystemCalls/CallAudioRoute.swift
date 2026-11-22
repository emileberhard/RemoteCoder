import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class CallAudioRoute {
    private enum Cue: String, CaseIterable {
        case connected = "voice-call-connected"
        case ended = "voice-call-ended"
    }

    private(set) var outputName: String?
    private(set) var isUsingSpeaker = false
    @ObservationIgnored private var listener: Task<Void, Never>?

    @ObservationIgnored private var cueData: [Cue: Data] = [:]
    @ObservationIgnored private var connectedCuePlayer: AVAudioPlayer?

    init() {
        Task { [weak self] in
            let data = await Self.loadCueData()
            self?.cueData = data
        }
    }

    @concurrent private static func loadCueData() async -> [Cue: Data] {
        var data: [Cue: Data] = [:]
        for cue in Cue.allCases {
            if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav") {
                data[cue] = try? Data(contentsOf: url)
            }
        }
        return data
    }

    func playConnectedCue(logger: AppLogger) {
        connectedCuePlayer = startCue(.connected, logger: logger)
    }

    func stopConnectedCue() {
        connectedCuePlayer?.stop()
        connectedCuePlayer = nil
    }

    func playEndedCue(logger: AppLogger) async {
        guard !Task.isCancelled, let player = startCue(.ended, logger: logger) else { return }
        defer { player.stop() }
        try? await Task.sleep(for: .seconds(min(player.duration, 0.35)))
    }

    private func startCue(_ cue: Cue, logger: AppLogger) -> AVAudioPlayer? {
        guard let data = cueData[cue] else {
            logger.error("Voice call cue unavailable: \(cue.rawValue)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(data: data)
            guard player.play() else {
                logger.error("Voice call cue could not start: \(cue.rawValue)")
                return nil
            }
            return player
        } catch {
            logger.error("Voice call cue failed: \(cue.rawValue) \(error.localizedDescription)")
            return nil
        }
    }

    func toggleSpeaker() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.overrideOutputAudioPort(isUsingSpeaker ? .none : .speaker)
        refresh()
    }

    func startListening() {
        listener?.cancel()
        refresh()
        listener = Task(name: "Realtime voice audio routes") { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
    }

    func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isUsingSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
        outputName = outputs.first?.portName
    }
}
