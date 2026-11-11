import Foundation
import SpeakerRecognition

struct DictationTranscript: Sendable {
    let text: String
    let everyone: String
    let model: String
    let everyoneModel: String
    let outcome: VoiceFilterOutcome?

    init(text: String, model: String) {
        self.text = text
        everyone = text
        self.model = model
        everyoneModel = model
        outcome = nil
    }

    init(text: String, everyone: String, model: String, everyoneModel: String, outcome: VoiceFilterOutcome?) {
        self.text = text
        self.everyone = everyone
        self.model = model
        self.everyoneModel = everyoneModel
        self.outcome = outcome
    }

    var removedVoices: Bool { (outcome?.droppedCount ?? 0) > 0 }
}
