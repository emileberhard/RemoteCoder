import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class CallAudioRoute {
    private(set) var outputName: String?
    private(set) var isUsingSpeaker = false
    @ObservationIgnored private var listener: Task<Void, Never>?

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
