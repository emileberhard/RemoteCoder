import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Serial image work avoids both main-actor stalls and parallel photo decode spikes.
actor ImagePreparation {
    static let shared = ImagePreparation()

    enum PreparationError: LocalizedError {
        case cannotDecode, cannotEncode, tooLarge
        var errorDescription: String? {
            switch self {
            case .cannotDecode: "The photo could not be decoded."
            case .cannotEncode: "The photo could not be encoded."
            case .tooLarge: "The photo could not fit within the size limit."
            }
        }
    }

    func thumbnail(data: Data, maxDimension: Int) throws -> DecodedImage? {
        try Task.checkCancellation()
        guard !data.isEmpty, maxDimension > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        try Task.checkCancellation()
        return DecodedImage.make(cgImage: image)
    }

    func thumbnail(reference: CodexAppServerV2.ImageReference, maxDimension: Int) throws -> DecodedImage? {
        guard case .inline(let url) = reference, url.hasPrefix("data:image/"),
              let delimiter = url.range(of: ";base64,"),
              let data = Data(base64Encoded: String(url[delimiter.upperBound...])) else { return nil }
        return try thumbnail(data: data, maxDimension: maxDimension)
    }

    func thumbnail(url: URL, maxDimension: Int) throws -> DecodedImage? {
        try Task.checkCancellation()
        guard maxDimension > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        try Task.checkCancellation()
        return DecodedImage.make(cgImage: image)
    }

    func deviceToolPhoto(from data: Data) throws -> CodexImageAttachment {
        guard let image = try thumbnail(data: data, maxDimension: 1568) else { throw PreparationError.cannotDecode }
        return try attachment(from: image, maxDimension: 1568, maxBytes: 700_000)
    }

    private func attachment(from image: DecodedImage, maxDimension: Int, maxBytes: Int) throws -> CodexImageAttachment {
        try Task.checkCancellation()
        let originalPixelSize = image.orientedPixelSize

        // Camera photos can be huge, which can exceed the gateway's websocket frame size
        // once base64-encoded into JSON. Downscale aggressively and keep bytes bounded so sending remains reliable.
        func downscaleIfNeeded(_ image: DecodedImage, pixelSize: CodexImagePixelSize, maxDimension: Int) throws -> (DecodedImage, CodexImagePixelSize) {
            let currentMax = max(pixelSize.width, pixelSize.height)
            guard currentMax > maxDimension else { return (image, pixelSize) }

            let scale = CGFloat(maxDimension) / CGFloat(currentMax)
            let newWidth = max(1, Int((CGFloat(pixelSize.width) * scale).rounded(.towardZero)))
            let newHeight = max(1, Int((CGFloat(pixelSize.height) * scale).rounded(.towardZero)))

            guard let resized = image.scaledOpaque(toPixelWidth: newWidth, height: newHeight) else { throw PreparationError.cannotEncode }
            return (resized, CodexImagePixelSize(width: newWidth, height: newHeight))
        }

        var (workingImage, workingPixelSize) = try downscaleIfNeeded(image, pixelSize: originalPixelSize, maxDimension: maxDimension)

        func encodeJPEG(_ image: DecodedImage, targetBytes: Int) -> Data? {
            var quality: CGFloat = 0.82
            guard var data = Self.jpegData(image, quality: quality), !data.isEmpty else { return nil }
            while data.count > targetBytes && quality > 0.46 {
                quality = max(0.46, quality - 0.08)
                guard let next = Self.jpegData(image, quality: quality) else { break }
                data = next
            }
            return data
        }

        guard var data = encodeJPEG(workingImage, targetBytes: maxBytes) else { throw PreparationError.cannotEncode }
        if data.count > maxBytes {
            (workingImage, workingPixelSize) = try downscaleIfNeeded(workingImage, pixelSize: workingPixelSize, maxDimension: 1280)
            guard let smaller = encodeJPEG(workingImage, targetBytes: maxBytes) else { throw PreparationError.cannotEncode }
            data = smaller
        }

        try Task.checkCancellation()
        guard !data.isEmpty else { throw PreparationError.cannotEncode }
        guard data.count <= maxBytes else { throw PreparationError.tooLarge }
        return CodexImageAttachment(id: UUID(), data: data, format: .jpeg, pixelSize: workingPixelSize)
    }

    private static func jpegData(_ image: DecodedImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.encodableCGImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: image.encodedOrientation.rawValue,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
