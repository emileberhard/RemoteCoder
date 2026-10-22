import Foundation

struct NotificationCursor: Equatable, Sendable {
    private(set) var sequence: UInt64? = nil
    private(set) var epoch: String? = nil

    @discardableResult
    mutating func adopt(epoch: String) -> Bool {
        let changed = self.epoch.map { $0 != epoch } ?? false
        if changed { sequence = nil }
        self.epoch = epoch
        return changed
    }

    mutating func advance(to sequence: UInt64) {
        guard epoch != nil, self.sequence.map({ sequence > $0 }) ?? true else { return }
        self.sequence = sequence
    }

    mutating func adoptConnection(epoch: String, deliveredThrough sequence: UInt64) {
        adopt(epoch: epoch)
        advance(to: sequence)
    }

    func replayAfter(pendingReplayFloor: UInt64?) -> UInt64? {
        guard let pendingReplayFloor else { return sequence }
        let beforeFloor = pendingReplayFloor == 0 ? 0 : pendingReplayFloor - 1
        guard let sequence else { return beforeFloor }
        return min(sequence, beforeFloor)
    }
}
