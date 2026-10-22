import Foundation
import UniformTypeIdentifiers

struct EmbeddedFileRequest: Sendable {
    let dataURL: String
    let suggestedName: String
}

struct StagedEmbeddedFile: Sendable {
    let url: URL
    let bytes: Int64

    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

enum EmbeddedFileError: Error, LocalizedError, Equatable {
    case invalid

    var errorDescription: String? { "The embedded file could not be read." }
}

enum EmbeddedFile {
    static let maximumBytes = 8 << 20
    static let maximumDataURLLength = (maximumBytes + 2) / 3 * 4 + 1_024
    static let maximumNameBytes = 200

    static func stage(_ request: EmbeddedFileRequest, in directory: URL) throws -> StagedEmbeddedFile {
        let (type, data) = try decode(request.dataURL)
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: filename(suggested: request.suggestedName, type: type), directoryHint: .notDirectory)
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return StagedEmbeddedFile(url: url, bytes: Int64(data.count))
    }

    static func decode(_ dataURL: String) throws -> (UTType?, Data) {
        guard dataURL.prefix(5).lowercased() == "data:", let comma = dataURL.firstIndex(of: ",") else {
            throw EmbeddedFileError.invalid
        }
        let parameters = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let mimeType = parameters.first ?? ""
        guard parameters.dropFirst().contains("base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            throw EmbeddedFileError.invalid
        }
        return (mimeType.isEmpty ? .plainText : UTType(mimeType: mimeType), data)
    }

    static func filename(suggested: String, type: UTType?) -> String {
        var base = String(String.UnicodeScalarView(suggested.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        var bytes = 0
        base = String(base.prefix { character in
            bytes += character.utf8.count
            return bytes <= maximumNameBytes
        }).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = defaultName(for: type) }
        let existing = (base as NSString).pathExtension
        if !existing.isEmpty, let existingType = UTType(filenameExtension: existing),
           type.map(existingType.conforms(to:)) ?? true {
            return base
        }
        guard let preferred = type?.preferredFilenameExtension else { return base }
        return base + "." + preferred
    }

    private static func defaultName(for type: UTType?) -> String {
        guard let type else { return "File" }
        if type.conforms(to: .image) { return "Image" }
        if type.conforms(to: .movie) { return "Video" }
        if type.conforms(to: .audio) { return "Audio" }
        return "File"
    }
}
