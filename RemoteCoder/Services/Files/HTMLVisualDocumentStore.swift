import Foundation

actor HTMLVisualDocumentStore {
    private let hostID: UUID
    private let access: any HostFileAccess
    private let cache: HTMLVisualDocumentCache
    private struct Pending {
        let id: UUID
        let work: Task<String, any Error>
        var consumers: Set<UUID>
    }
    private var pending: [HTMLVisualReference: Pending] = [:]
    private var queue: Task<Void, Never>?
    private var retired = false

    init(hostID: UUID, access: any HostFileAccess, cache: HTMLVisualDocumentCache) {
        self.hostID = hostID
        self.access = access
        self.cache = cache
    }

    func document(_ reference: HTMLVisualReference) async throws -> String {
        try validate()
        let id = UUID()
        let work: Task<String, any Error>
        if var current = pending[reference] {
            guard current.consumers.count < 64 else { throw HostFileError.busy }
            current.consumers.insert(id)
            pending[reference] = current
            work = current.work
            if work.isCancelled {
                defer { release(reference, consumer: id) }
                _ = await work.result
                try validate()
                return try await document(reference)
            }
        } else {
            guard pending.count < 24 else { throw HostFileError.busy }
            let previous = queue
            let operationID = UUID()
            work = Task {
                defer {
                    if pending[reference]?.id == operationID { pending.removeValue(forKey: reference) }
                }
                await previous?.value
                try validate()
                if let html = try await cache.document(hostID: hostID, reference: reference) {
                    try validate()
                    return html
                }
                let lease: HostFileLease
                do {
                    lease = try await access.openVisual(reference: reference) { _ in }
                } catch {
                    if error as? HostFileError == .tooLarge { throw HTMLVisualError.tooLarge }
                    throw error
                }
                let html: String
                do {
                    try validate()
                    guard lease.metadata.bytes <= Int64(HTMLVisualReference.maximumBytes) else { throw HTMLVisualError.tooLarge }
                    html = try await cache.store(hostID: hostID, reference: reference, source: lease.url)
                } catch {
                    await access.release(lease)
                    throw error
                }
                await access.release(lease)
                try validate()
                return html
            }
            pending[reference] = Pending(id: operationID, work: work, consumers: [id])
            queue = Task { _ = await work.result }
        }
        defer { release(reference, consumer: id) }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try validate()
            return result
        } onCancel: {
            Task { await self.release(reference, consumer: id) }
        }
    }

    func beginRetirement() {
        retired = true
        for value in pending.values { value.work.cancel() }
    }

    func retire() async {
        beginRetirement()
        let running = pending.values.map(\.work)
        for work in running { _ = await work.result }
        queue = nil
    }

    func prefetch(_ reference: HTMLVisualReference) async {
        guard pending.count < 20 || pending[reference] != nil else { return }
        _ = try? await document(reference)
    }

    private func release(_ reference: HTMLVisualReference, consumer: UUID) {
        guard var value = pending[reference], value.consumers.remove(consumer) != nil else { return }
        if value.consumers.isEmpty {
            value.work.cancel()
        }
        pending[reference] = value
    }

    private func validate() throws {
        try Task.checkCancellation()
        guard !retired else { throw HostFileError.retired }
    }
}
