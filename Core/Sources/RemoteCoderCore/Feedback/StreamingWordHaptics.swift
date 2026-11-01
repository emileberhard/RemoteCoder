import Foundation

struct StreamingWordHaptics {
    private struct Part {
        let begin: TimeInterval
        let punch: Float
    }

    private var parts: [Part] = []
    private var newestBegin = -TimeInterval.infinity
    private var markedCount = 0

    var hasPending: Bool { !parts.isEmpty }

    mutating func update(begins: [TimeInterval]) {
        precondition(begins == Set(begins).sorted())
        parts.removeAll { !begins.contains($0.begin) }
        for begin in begins where begin > newestBegin {
            newestBegin = begin
            guard markedCount < StreamingHapticRecipe.wordCount else { continue }
            parts.append(Part(begin: begin, punch: StreamingHapticRecipe.punch(at: markedCount)))
            markedCount += 1
        }
    }

    mutating func next(at time: TimeInterval) -> Float? {
        let due = parts.last { $0.begin < time }
        parts.removeAll { $0.begin < time }
        guard let due, time - due.begin <= StreamingRevealSchedule.stagger else { return nil }
        return due.punch
    }

    mutating func discard() { parts.removeAll() }
}
