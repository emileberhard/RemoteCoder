import Foundation

struct DeviceToolsDeclare: Codable, Sendable, Equatable {
    struct Tool: Codable, Sendable, Equatable {
        let name: String
        let version: Int
    }

    let tools: [Tool]
}

struct DeviceToolInvoke: Codable, Sendable, Equatable {
    let operationId: String
    let tool: String
    let version: Int
    let arguments: JSONValue
    let deadlineUnixMs: Int64
}

struct DeviceToolCancel: Codable, Sendable, Equatable {
    let operationId: String
}

enum DeviceToolOutcome: String, Codable, Sendable {
    case succeeded, refused, failed, cancelled
}

enum DeviceToolRefusalReason: String, Codable, Sendable {
    case foregroundRequired = "foreground_required"
    case permissionDenied = "permission_denied"
    case cameraUnavailable = "camera_unavailable"
    case lensUnavailable = "lens_unavailable"
    case busy
    case invalidArguments = "invalid_arguments"
    case deadlinePassed = "deadline_passed"
}

enum DeviceToolContent: Codable, Sendable, Equatable {
    case text(String)
    case image(mimeType: String, data: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, mimeType, data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "image": self = .image(mimeType: try container.decode(String.self, forKey: .mimeType),
                                   data: try container.decode(String.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown device tool content type.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mimeType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(data, forKey: .data)
        }
    }
}

enum PhotoCamera: String, Codable, Sendable {
    case back, front
}

enum PhotoLens: String, Codable, Sendable, CaseIterable {
    case wide, telephoto
    case ultraWide = "ultra_wide"
}

struct DeviceToolOriginal: Codable, Sendable, Equatable {
    let path: String
    let sha256: String
    let bytes: Int64
    let camera: PhotoCamera
    let lens: PhotoLens
    let width: Int
    let height: Int
}

struct DeviceToolResult: Codable, Sendable, Equatable {
    let operationId: String
    let outcome: DeviceToolOutcome
    let reason: DeviceToolRefusalReason?
    let detail: String?
    let content: [DeviceToolContent]?
    let originals: [DeviceToolOriginal]?
}

struct DeviceToolResultReceipt: Codable, Sendable, Equatable {
    let accepted: Bool
}

struct TakePhotoArguments: Decodable, Sendable, Equatable {
    enum Camera: String, Decodable, Sendable {
        case back, front, both
    }

    let camera: Camera
    let lens: PhotoLens

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ArgumentKey.self)
        guard container.allKeys.allSatisfy({ $0.stringValue == "camera" || $0.stringValue == "lens" }) else {
            throw DeviceToolRefusal(reason: .invalidArguments, detail: "take_photo accepts only camera and lens.")
        }
        let cameraKey = ArgumentKey(stringValue: "camera")
        let lensKey = ArgumentKey(stringValue: "lens")
        camera = container.contains(cameraKey) ? try container.decode(Camera.self, forKey: cameraKey) : .back
        lens = container.contains(lensKey) ? try container.decode(PhotoLens.self, forKey: lensKey) : .wide
        guard camera != .front || lens == .wide else {
            throw DeviceToolRefusal(reason: .invalidArguments, detail: "The front camera supports only the wide lens.")
        }
    }

    var captures: [(camera: PhotoCamera, lens: PhotoLens)] {
        switch camera {
        case .back: [(.back, lens)]
        case .front: [(.front, .wide)]
        case .both: [(.back, lens), (.front, .wide)]
        }
    }

    private struct ArgumentKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
