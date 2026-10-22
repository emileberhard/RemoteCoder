import Foundation

struct WaveformSamples {
    private(set) var values: [CGFloat] = Array(repeating: 0, count: 120)

    mutating func append(_ level: Float) {
        let level = level.isFinite ? min(1, max(0, CGFloat(level))) : 0
        let previous = values.last ?? 0
        values.append(previous + (level - previous) * 0.45)
        if values.count > 140 { values.removeFirst(values.count - 140) }
    }
}

final class WaveformTrace {
    private(set) var samples = WaveformSamples()
    private var sampledAt: Date?

    func advance(to date: Date, every interval: Duration, level: () -> Float) -> CGFloat {
        let period = interval / .seconds(1)
        guard period > 0, let last = sampledAt, date >= last, date.timeIntervalSince(last) < period * 8 else {
            sampledAt = date
            samples.append(level())
            return 0
        }
        let due = Int(date.timeIntervalSince(last) / period)
        if due > 0 {
            let current = level()
            for _ in 0..<due { samples.append(current) }
        }
        let next = last.addingTimeInterval(Double(due) * period)
        sampledAt = next
        return CGFloat(min(date.timeIntervalSince(next) / period, 1))
    }
}
