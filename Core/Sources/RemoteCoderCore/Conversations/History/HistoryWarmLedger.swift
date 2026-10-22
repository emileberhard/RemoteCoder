import Foundation

/// A read covers one header revision and exactly the notifications observed before
/// it began; a warm additionally covers the HTML visual preparation context it
/// prepared for. Later notifications, revisions or contexts remain eligible again.
/// Invalidation and clearing also end every earlier observation's coverage.
struct HistoryWarmLedger: Sendable {
    struct Observation: Equatable, Sendable {
        let revision: Int64
        let epoch: UInt64
        let change: UInt64
    }
    private struct Entry {
        var change: UInt64
        var access: UInt64
        var warmed: Observation?
        var warmedContext: HTMLVisualPreparationContext?
        var read: Observation?
    }
    private static let capacity = ConversationHeaderRetention.countLimit
    private var epoch: UInt64 = 0
    private var nextChange: UInt64 = 0
    private var accesses: UInt64 = 0
    private var entries: [String: Entry] = [:]

    mutating func changed(_ threadID: String) {
        retain(threadID)
        nextChange &+= 1
        entries[threadID]?.change = nextChange
    }
    func observation(threadID: String, revision: Int64) -> Observation {
        Observation(revision: revision, epoch: epoch, change: entries[threadID]?.change ?? nextChange)
    }
    func needsWarm(threadID: String, revision: Int64, context: HTMLVisualPreparationContext?) -> Bool {
        entries[threadID]?.warmed != observation(threadID: threadID, revision: revision)
            || entries[threadID]?.warmedContext != context
    }
    func readCovers(threadID: String, revision: Int64) -> Bool? {
        guard let entry = entries[threadID] else { return nil }
        return entry.read == observation(threadID: threadID, revision: revision)
    }
    mutating func readSucceeded(threadID: String, observation: Observation) {
        guard observation == self.observation(threadID: threadID, revision: observation.revision) else { return }
        retain(threadID)
        entries[threadID]?.read = observation
    }
    mutating func succeeded(threadID: String, observation: Observation, context: HTMLVisualPreparationContext?) {
        guard observation == self.observation(threadID: threadID, revision: observation.revision) else { return }
        retain(threadID)
        entries[threadID]?.warmed = observation
        entries[threadID]?.warmedContext = context
        entries[threadID]?.read = observation
    }
    mutating func invalidate(_ threadID: String) {
        entries[threadID]?.warmed = nil
        changed(threadID)
    }
    mutating func clear() {
        entries.removeAll()
        epoch &+= 1
    }

    private mutating func retain(_ threadID: String) {
        accesses &+= 1
        entries[threadID, default: Entry(change: nextChange, access: accesses)].access = accesses
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
            nextChange &+= 1
        }
    }
}
