import Foundation

struct StreamingRevealSchedule: Equatable, Sendable {
    static let fadeDuration: TimeInterval = 0.5
    static let stagger: TimeInterval = 0.07
    static let backlogThreshold: TimeInterval = 0.3
    private static let catchUpRate: Double = 20

    private(set) var lastStart = -TimeInterval.infinity

    mutating func start(at now: TimeInterval) -> TimeInterval {
        let backlog = max(0, lastStart - now)
        let advance = backlog > Self.backlogThreshold
            ? Self.stagger / (1 + (backlog - Self.backlogThreshold) * Self.catchUpRate)
            : Self.stagger
        let start = max(now, lastStart + advance)
        lastStart = start
        return start
    }
}

enum StreamingRevealText {
    static func units(in text: some Collection<Character>, from offset: Int, limit: Int) -> [Range<Int>] {
        precondition(limit > 0)
        var starts: [Int] = []
        var length = 0
        var previousIsWhitespace = false
        for character in text {
            let isWhitespace = character.isWhitespace
            if length >= offset, !isWhitespace, length == offset || previousIsWhitespace {
                starts.append(length)
            }
            previousIsWhitespace = isWhitespace
            length += character.utf16.count
        }
        let merged = Swift.stride(from: 0, to: starts.count, by: max(1, (starts.count + limit - 1) / limit))
            .map { starts[$0] }
        return merged.indices.map { index in
            merged[index]..<(index + 1 < merged.count ? merged[index + 1] : length)
        }
    }

    static func commonPrefixLength(_ lhs: some Collection<Character>, _ rhs: some Collection<Character>) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.reduce(0) { $0 + $1.0.utf16.count }
    }

    static func continuesWord(_ text: some Collection<Character>, at offset: Int) -> Bool {
        var length = 0
        var previous: Character?
        for character in text {
            guard length < offset else {
                return length == offset && previous.map { !$0.isWhitespace && !character.isWhitespace } == true
            }
            previous = character
            length += character.utf16.count
        }
        return false
    }
}
