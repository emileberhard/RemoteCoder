import ImageIO
import SwiftUI
import UIKit

typealias DecodedImage = UIImage

extension DecodedImage {
    static func make(cgImage: CGImage) -> DecodedImage {
        UIImage(cgImage: cgImage)
    }

    @concurrent
    static func prepared(from data: Data) async -> DecodedImage? {
        guard let decoded = UIImage(data: data) else { return nil }
        return await decoded.byPreparingForDisplay()
    }

    var encodableCGImage: CGImage? { cgImage }

    var encodedOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    var orientedPixelSize: CodexImagePixelSize {
        if let cg = cgImage {
            // Camera captures often arrive as "landscape pixels + orientation metadata".
            // Our downscaler renders into a fixed pixel buffer, so we must use an
            // orientation-correct pixel size or portrait shots get stretched to landscape.
            let w = cg.width
            let h = cg.height
            switch imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return CodexImagePixelSize(width: h, height: w)
            default:
                return CodexImagePixelSize(width: w, height: h)
            }
        }
        let width = Int((size.width * scale).rounded(.towardZero))
        let height = Int((size.height * scale).rounded(.towardZero))
        return CodexImagePixelSize(width: max(1, width), height: max(1, height))
    }

    func scaledOpaque(toPixelWidth width: Int, height: Int) -> DecodedImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            format: format
        )
        return renderer.image { _ in
            draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }
}

extension Image {
    init(decoded: DecodedImage) {
        self.init(uiImage: decoded)
    }
}
