import Foundation

struct WaveformSamples {
    static let capacity = 140
    private(set) var values: [CGFloat] = Array(repeating: 0, count: 120)

    mutating func append(_ level: Float) {
        let level = level.isFinite ? min(1, max(0, CGFloat(level))) : 0
        let previous = values.last ?? 0
        values.append(previous + (level - previous) * 0.45)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }
}
