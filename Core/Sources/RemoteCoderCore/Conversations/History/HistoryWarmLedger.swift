import Foundation

/// A read covers one header revision and exactly the notifications observed before
/// it began; a warm additionally covers the HTML visual preparation context it
/// prepared for, which matters only when the warmed tail references visuals.
/// Later notifications, revisions or contexts remain eligible again.
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
        var visuals: [HTMLVisualReference] = []
        var read: Observation?
    }
    private static let capacity = ConversationHeaderRetention.countLimit
    private var epoch: UInt64 = 0
    private var nextChange: UInt64 = 0
    private var absentChange: UInt64 = 0
    private var accesses: UInt64 = 0
    private var entries: [String: Entry] = [:]

    mutating func changed(_ threadID: String) {
        retain(threadID)
        nextChange &+= 1
        entries[threadID]?.change = nextChange
    }
    func observation(threadID: String, revision: Int64) -> Observation {
        Observation(revision: revision, epoch: epoch, change: entries[threadID]?.change ?? absentChange)
    }
    func needsWarm(threadID: String, revision: Int64, context: HTMLVisualPreparationContext?) -> Bool {
        guard let entry = entries[threadID] else { return true }
        let current = observation(threadID: threadID, revision: revision)
        guard let context else { return entry.read != current }
        guard entry.warmed == current else { return true }
        return !entry.visuals.isEmpty && entry.warmedContext != context
    }
    func pendingVisuals(threadID: String, revision: Int64, context: HTMLVisualPreparationContext) -> [HTMLVisualReference]? {
        guard let entry = entries[threadID], entry.warmed == observation(threadID: threadID, revision: revision),
              !entry.visuals.isEmpty, entry.warmedContext != context else { return nil }
        return entry.visuals
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
    mutating func succeeded(threadID: String, observation: Observation, context: HTMLVisualPreparationContext?,
                            visuals: [HTMLVisualReference]) {
        guard observation == self.observation(threadID: threadID, revision: observation.revision) else { return }
        retain(threadID)
        if entries[threadID]?.warmed != observation || context != nil {
            entries[threadID]?.warmedContext = context
        }
        entries[threadID]?.warmed = observation
        entries[threadID]?.visuals = visuals
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
        entries[threadID, default: Entry(change: absentChange, access: accesses)].access = accesses
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
            nextChange &+= 1
            absentChange = nextChange
        }
    }
}
