import Foundation
import ImageIO
import LinkPresentation
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class SiteIcon {
    fileprivate(set) var image: Image?
}

@MainActor
final class SiteIconStore {
    private static let capacity = 256
    private static let entryLimit = 384
    private static let fetchConcurrency = 2
    private static let queueLimit = 32
    private static let refreshAge: TimeInterval = 30 * 86_400
    private static let failureBackoff: TimeInterval = 10 * 60
    private static let missingIconBackoff: TimeInterval = 86_400

    private enum State {
        case idle
        case queued
        case fetching
        case waiting(until: Date)
    }

    @MainActor private struct Entry {
        let icon = SiteIcon()
        var state = State.idle
        var fetchedAt: Date?
        var lastUse: UInt64 = 0

        var isBusy: Bool {
            switch state {
            case .queued, .fetching: true
            case .idle, .waiting: false
            }
        }
    }

    private let disk: SiteIconDisk
    private let logger = AppLogger(category: "SiteIcons")
    private var entries: [String: Entry] = [:]
    private var queue: [String] = []
    private var fetches: [String: Task<Void, Never>] = [:]
    private var useCounter: UInt64 = 0

    init(directory: URL) {
        disk = SiteIconDisk(directory: directory, capacity: Self.capacity)
        Task { [disk, weak self] in
            let stored = await disk.load()
            self?.adopt(stored)
        }
    }

    func icon(for host: String) -> SiteIcon {
        touch(host).icon
    }

    func request(_ hosts: Set<String>) {
        let now = Date.now
        for host in hosts {
            var entry = touch(host)
            switch entry.state {
            case .queued, .fetching:
                continue
            case .waiting(let until) where until > now:
                continue
            case .idle, .waiting:
                if entry.icon.image != nil, let fetchedAt = entry.fetchedAt,
                   now.timeIntervalSince(fetchedAt) < Self.refreshAge { continue }
            }
            if queue.count == Self.queueLimit {
                entries[queue.removeFirst()]?.state = .idle
            }
            entry.state = .queued
            entries[host] = entry
            queue.append(host)
        }
        startFetches()
    }

    func stopFetching() {
        for host in queue { entries[host]?.state = .idle }
        queue = []
        for (host, fetch) in fetches {
            fetch.cancel()
            entries[host]?.state = .idle
        }
        fetches = [:]
    }

    private func touch(_ host: String) -> Entry {
        useCounter += 1
        var entry = entries[host] ?? Entry()
        entry.lastUse = useCounter
        entries[host] = entry
        if entries.count > Self.entryLimit { evict() }
        return entry
    }

    private func evict() {
        let idle = entries.filter { !$0.value.isBusy }
        let excess = entries.count - Self.entryLimit
        for (host, _) in idle.sorted(by: { $0.value.lastUse < $1.value.lastUse }).prefix(excess) {
            entries[host] = nil
        }
    }

    private func adopt(_ stored: [StoredSiteIcon]) {
        for icon in stored where entries[icon.host]?.icon.image == nil {
            var entry = entries[icon.host] ?? Entry()
            entry.icon.image = Image(decoded: icon.image)
            entry.fetchedAt = icon.fetchedAt
            entries[icon.host] = entry
        }
        if entries.count > Self.entryLimit { evict() }
    }

    private func startFetches() {
        while fetches.count < Self.fetchConcurrency, !queue.isEmpty {
            let host = queue.removeFirst()
            entries[host]?.state = .fetching
            fetches[host] = Task { [disk, weak self] in
                let result: SiteIconFetchResult
                do {
                    result = try await SiteIconFetch.icon(host: host)
                } catch {
                    result = .failed
                }
                guard !Task.isCancelled else { return }
                if case .icon(let prepared) = result { await disk.store(prepared.png, host: host) }
                guard !Task.isCancelled else { return }
                self?.finish(host, result: result)
            }
        }
    }

    private func finish(_ host: String, result: SiteIconFetchResult) {
        fetches[host] = nil
        if var entry = entries[host] {
            let now = Date.now
            switch result {
            case .icon(let prepared):
                entry.icon.image = Image(decoded: prepared.image)
                entry.fetchedAt = now
                entry.state = .idle
            case .missing:
                entry.state = .waiting(until: now.addingTimeInterval(Self.missingIconBackoff))
            case .failed:
                logger.notice("site icon fetch failed")
                entry.state = .waiting(until: now.addingTimeInterval(Self.failureBackoff))
            }
            entries[host] = entry
        }
        startFetches()
    }
}

extension EnvironmentValues {
    @Entry var siteIcons: SiteIconStore?
}

private struct PreparedSiteIcon: Sendable {
    let image: DecodedImage
    let png: Data
}

private enum SiteIconFetchResult: Sendable {
    case icon(PreparedSiteIcon)
    case missing
    case failed
}

private struct StoredSiteIcon: Sendable {
    let host: String
    let image: DecodedImage
    let fetchedAt: Date
}

private enum SiteIconFetch {
    static let pixelSize = 64
    private static let logger = AppLogger(category: "SiteIcons")

    @concurrent
    static func icon(host: String) async throws -> SiteIconFetchResult {
        #if RC_PERF_HARNESS
        if AppStorageScope.isOfflineReplay {
            PerformanceReplayHTTP.omitSiteIcon()
            return .missing
        }
        #endif
        guard let url = URL(string: "https://\(host)/") else { return .missing }
        let metadata = try await LinkMetadata(fetching: url, timeout: .seconds(8), includeSubresources: true)
        guard let data = try await metadata.media(.icon, as: Data.self) else { return .missing }
        guard let image = try await ImagePreparation.shared.thumbnail(data: data, maxDimension: pixelSize),
              let cgImage = image.encodableCGImage, let png = png(cgImage) else {
            logger.notice("site icon undecodable")
            return .missing
        }
        return .icon(PreparedSiteIcon(image: image, png: png))
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

private actor SiteIconDisk {
    private let directory: URL
    private let capacity: Int

    init(directory: URL, capacity: Int) {
        self.directory = directory
        self.capacity = capacity
    }

    func load() async -> [StoredSiteIcon] {
        var stored: [StoredSiteIcon] = []
        for file in prunedFiles() {
            guard let image = try? await ImagePreparation.shared.thumbnail(url: file.url, maxDimension: SiteIconFetch.pixelSize) else {
                try? FileManager.default.removeItem(at: file.url)
                continue
            }
            stored.append(StoredSiteIcon(host: file.url.deletingPathExtension().lastPathComponent, image: image, fetchedAt: file.modified))
        }
        return stored
    }

    func store(_ png: Data, host: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appending(path: "\(host).png"), options: .atomic)
        } catch {
            return
        }
        _ = prunedFiles()
    }

    private func prunedFiles() -> [(url: URL, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let files = urls.filter { $0.pathExtension == "png" }.map { url in
            (url: url, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
        for file in files.dropFirst(capacity) { try? FileManager.default.removeItem(at: file.url) }
        return Array(files.prefix(capacity))
    }
}
