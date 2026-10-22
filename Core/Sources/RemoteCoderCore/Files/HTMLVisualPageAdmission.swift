import Foundation

struct HTMLVisualPageAdmission {
    enum Kind: Equatable { case automatic, selected, preparation }
    static let maximumLivePages = 3
    static let maximumWaiting = 16

    private(set) var live: [UUID] = []
    private(set) var waiting: [UUID] = []
    private var pinned: Set<UUID> = []
    private var kinds: [UUID: Kind] = [:]
    private(set) var automaticLimit = maximumLivePages

    mutating func request(_ id: UUID, kind: Kind) throws -> Bool {
        precondition(!live.contains(id) && !waiting.contains(id))
        if live.count < Self.maximumLivePages && permits(kind) {
            kinds[id] = kind
            live.append(id)
            return true
        }
        guard waiting.count < Self.maximumWaiting else { throw HTMLVisualAdmissionError.busy }
        kinds[id] = kind
        waiting.append(id)
        return false
    }

    mutating func remove(_ id: UUID) -> UUID? {
        waiting.removeAll { $0 == id }
        pinned.remove(id)
        kinds.removeValue(forKey: id)
        guard let index = live.firstIndex(of: id) else { return nil }
        live.remove(at: index)
        return admitWaiting()
    }

    mutating func pin(_ id: UUID, active: Bool) {
        guard live.contains(id) else { return }
        if active { pinned.insert(id) } else { pinned.remove(id) }
    }

    mutating func prioritize(_ id: UUID) {
        if kinds[id] != nil { kinds[id] = .selected }
        guard let index = waiting.firstIndex(of: id) else { return }
        waiting.remove(at: index)
        waiting.insert(id, at: 0)
    }

    mutating func conserveEnergy(_ conserve: Bool) -> [UUID] {
        automaticLimit = conserve ? 1 : Self.maximumLivePages
        let background = live.filter { kinds[$0] == .automatic } + live.filter { kinds[$0] == .preparation }
        return background.dropFirst(automaticLimit).filter { !pinned.contains($0) }
    }

    mutating func admitWaiting() -> UUID? {
        guard live.count < Self.maximumLivePages,
              let index = waiting.firstIndex(where: { kinds[$0] != .preparation && permits(kinds[$0] ?? .automatic) })
                ?? waiting.firstIndex(where: { permits(kinds[$0] ?? .automatic) }) else { return nil }
        let next = waiting.remove(at: index)
        live.append(next)
        return next
    }

    private func permits(_ kind: Kind) -> Bool {
        kind == .selected || live.filter { kinds[$0] != .selected }.count < automaticLimit
    }

    func evictionCandidate(excluding id: UUID) -> UUID? {
        live.first { $0 != id && kinds[$0] == .preparation } ?? live.first { $0 != id && !pinned.contains($0) }
    }

    func preparationBlocking(_ id: UUID) -> UUID? {
        guard waiting.contains(id), kinds[id] != .preparation else { return nil }
        return live.first { kinds[$0] == .preparation }
    }
}

enum HTMLVisualAdmissionError: Error, LocalizedError {
    case busy

    var errorDescription: String? { "Other HTML visuals are still loading. Try again." }
}
