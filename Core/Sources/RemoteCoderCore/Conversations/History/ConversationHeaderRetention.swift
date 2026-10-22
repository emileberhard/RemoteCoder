import Foundation

enum ConversationHeaderRetention {
    static let countLimit = 1_024

    struct Result: Sendable {
        let threads: [ConversationHeader]
        let discarded: Bool
    }

    static func retain(_ threads: [ConversationHeader], prioritizing protectedIDs: Set<String>, pinned pinIDs: Set<String>, promoting promotedIDs: Set<String>) -> Result {
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        func tier(_ header: ConversationHeader) -> Int {
            if protectedIDs.contains(header.id) { return 0 }
            if pinIDs.contains(header.id) { return 1 }
            if promotedIDs.contains(header.id) { return 2 }
            return 3
        }
        let retained = byID.values.sorted {
            let first = tier($0), second = tier($1)
            if first != second { return first < second }
            return $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
        .prefix(countLimit)
        .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        return Result(threads: retained, discarded: retained.count < byID.count)
    }
}
