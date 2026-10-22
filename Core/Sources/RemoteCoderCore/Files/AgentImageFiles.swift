import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AgentImageFiles {
    private static let readableTypes: [UTType] = [.jpeg, .png, .gif, .webP]
    private static let convertedTypes: [UTType] = [.heif, .heic, .tiff, .rawImage]

    static func preferredType(among available: [UTType]) -> UTType? {
        available.first { type in readableTypes.contains(where: type.conforms(to:)) }
            ?? available.first { $0.conforms(to: .image) }
    }

    @concurrent
    static func write(_ image: PastedImage) async throws -> URL {
        let name = "pasted-\(UUID().uuidString.prefix(8).lowercased()).\(image.type.preferredFilenameExtension ?? "image")"
        return try DeferredImportFile.scratchFile(named: name, containing: image.data)
    }

    static func readable(_ file: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              convertedTypes.contains(where: type.conforms(to:)) else { return file }
        let count = CGImageSourceGetCount(source)
        guard count == 1 || (count > 1 && !type.conforms(to: .tiff)) else { return file }
        let encoded = file.deletingLastPathComponent().appending(path: "converting-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: encoded) }
        guard let destination = CGImageDestinationCreateWithURL(encoded as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw UploadStaging.Failure(message: "Could not convert \(file.lastPathComponent) to JPEG.")
        }
        CGImageDestinationAddImageFromSource(destination, source, CGImageSourceGetPrimaryImageIndex(source),
                                             [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw UploadStaging.Failure(message: "Could not convert \(file.lastPathComponent) to JPEG.")
        }
        let jpeg = file.deletingPathExtension().appendingPathExtension("jpg")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: encoded, to: jpeg)
        return jpeg
    }
}

struct PastedImage: Sendable {
    let data: Data
    let type: UTType
}
