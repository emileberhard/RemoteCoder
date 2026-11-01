import Foundation

struct StreamingWordHaptics {
    private struct Part {
        let begin: TimeInterval
        var needsHaptic: Bool
    }

    private var parts: [Part] = []
    private var hasStarted = false

    var hasPending: Bool { parts.contains(where: \.needsHaptic) }

    mutating func update(begins: [TimeInterval]) {
        precondition(begins == Set(begins).sorted())
        let previous = Dictionary(uniqueKeysWithValues: parts.map { ($0.begin, $0.needsHaptic) })
        parts = begins.map { Part(begin: $0, needsHaptic: previous[$0] ?? false) }
        guard !parts.isEmpty else { return }
        if !hasStarted || parts.last?.needsHaptic == true {
            for index in parts.indices.prefix(StreamingHapticRecipe.wordCount) { parts[index].needsHaptic = true }
        }
        hasStarted = true
    }

    mutating func next(at time: TimeInterval) -> Float? {
        var punch: Float?
        for index in parts.indices.reversed() {
            let age = time - parts[index].begin
            if age >= StreamingRevealSchedule.fadeDuration {
                parts.remove(at: index)
            } else if age > 0, parts[index].needsHaptic, punch == nil {
                parts[index].needsHaptic = false
                punch = StreamingHapticRecipe.punch(at: index)
            }
        }
        return punch
    }

    mutating func discard() {
        for index in parts.indices { parts[index].needsHaptic = false }
    }
}
