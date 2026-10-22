import Foundation

struct ReplayProgress: Sendable {
    static let pageLimit = 8

    struct Page: Decodable, Sendable {
        struct Skipped: Decodable, Sendable {
            let sequence: UInt64
            let threadId: String?
        }

        let epoch: String
        let throughSequence: UInt64
        let hasMore: Bool
        let evictedBefore: Bool
        let skipped: [Skipped]
    }

    enum Gap: Equatable, Sendable {
        case allThreads
        case threads(Set<String>)
    }

    struct Step: Sendable {
        let gap: Gap?
        let hasMore: Bool
    }

    private(set) var cursor: NotificationCursor
    private(set) var nextAfterSequence: UInt64
    private(set) var pageCount = 0

    init(cursor: NotificationCursor, afterSequence: UInt64) {
        self.cursor = cursor
        nextAfterSequence = afterSequence
    }

    mutating func complete(_ page: Page) -> Step {
        let changedEpoch = cursor.adopt(epoch: page.epoch)
        let stalled = page.hasMore && !changedEpoch && page.throughSequence <= nextAfterSequence
        cursor.advance(to: page.throughSequence)
        nextAfterSequence = page.throughSequence
        pageCount += 1

        var skippedThreads = Set<String>()
        var unknownSkipped = false
        for skipped in page.skipped {
            guard let threadID = skipped.threadId else { unknownSkipped = true; break }
            skippedThreads.insert(threadID)
            if skippedThreads.count > 256 { unknownSkipped = true; break }
        }
        let bounded = page.hasMore && pageCount >= Self.pageLimit
        let gap: Gap?
        if page.evictedBefore || changedEpoch || unknownSkipped || bounded || stalled {
            gap = .allThreads
        } else if !skippedThreads.isEmpty {
            gap = .threads(skippedThreads)
        } else {
            gap = nil
        }
        return Step(gap: gap, hasMore: page.hasMore && !bounded && !stalled)
    }
}
