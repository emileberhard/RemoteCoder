import Foundation

actor HTMLVisualDocumentCache {
    private let directory: URL
    private let writer: any HTMLVisualDocumentWriting
    private let admission = HostFilePathAdmission()
    private static let maximumBytes = 64 << 20
    private static let maximumEntries = 256

    init(directory: URL, writer: any HTMLVisualDocumentWriting) {
        self.directory = directory
        self.writer = writer
    }

    func document(hostID: UUID, reference: HTMLVisualReference) throws -> String? {
        try Task.checkCancellation()
        let url = location(hostID: hostID, reference: reference)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o222 == 0 else { throw HTMLVisualError.invalidCache }
        let data = try Self.readBounded(url)
        guard let html = String(data: data, encoding: .utf8) else { throw HTMLVisualError.invalidCache }
        return html
    }

    func store(hostID: UUID, reference: HTMLVisualReference, source: URL) async throws -> String {
        try await admission.acquire("publication")
        let html: String
        do {
            html = try await storeAdmitted(hostID: hostID, reference: reference, source: source)
        } catch {
            await admission.release("publication")
            throw error
        }
        await admission.release("publication")
        return html
    }

    private func storeAdmitted(hostID: UUID, reference: HTMLVisualReference, source: URL) async throws -> String {
        try Task.checkCancellation()
        let data = try Self.readBounded(source)
        let html = try reference.verify(data)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let destination = location(hostID: hostID, reference: reference)
        if let cached = try document(hostID: hostID, reference: reference) { return cached }
        try trim(incomingBytes: data.count)
        let temporary = directory.appending(path: UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await writer.writeReadOnlyTemporary(data, to: temporary)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return html
    }

    private func location(hostID: UUID, reference: HTMLVisualReference) -> URL {
        directory.appending(path: hostID.uuidString + "-" + reference.digest + ".html")
    }

    private func trim(incomingBytes: Int) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey])
        var entries: [(url: URL, bytes: Int, created: Date)] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let bytes = values.fileSize, let created = values.creationDate else {
                throw HTMLVisualError.invalidCache
            }
            entries.append((url, bytes, created))
        }
        entries.sort { $0.created < $1.created }
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        var count = entries.count
        for entry in entries {
            guard bytes + incomingBytes > Self.maximumBytes || count >= Self.maximumEntries else { break }
            try FileManager.default.removeItem(at: entry.url)
            bytes -= entry.bytes
            count -= 1
        }
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = HTMLVisualReference.maximumBytes + 1 - data.count
            guard remaining > 0 else { throw HTMLVisualError.tooLarge }
            guard let chunk = try file.read(upToCount: min(64 << 10, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= HTMLVisualReference.maximumBytes else { throw HTMLVisualError.tooLarge }
        }
        return data
    }
}
