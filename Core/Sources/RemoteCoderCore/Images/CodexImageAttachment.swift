import Foundation

enum CodexImageFormat: String, Sendable, Codable {
    case png
    case jpeg

    var fileExtension: String {
        switch self {
        case .png:
            return "png"
        case .jpeg:
            return "jpg"
        }
    }

    var displayName: String {
        switch self {
        case .png:
            return "PNG"
        case .jpeg:
            return "JPEG"
        }
    }
}

struct CodexImagePixelSize: Sendable, Equatable, Codable {
    let width: Int
    let height: Int
}

struct CodexImageAttachment: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let data: Data
    let format: CodexImageFormat
    let pixelSize: CodexImagePixelSize

    var byteCount: Int { data.count }

    var fileName: String {
        "image-\(id.uuidString.lowercased()).\(format.fileExtension)"
    }
}
