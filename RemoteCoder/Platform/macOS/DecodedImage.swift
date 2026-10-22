#if os(macOS)
import AppKit
import ImageIO
import SwiftUI

typealias DecodedImage = NSImage

extension DecodedImage {
    static func make(cgImage: CGImage) -> DecodedImage {
        NSImage(cgImage: cgImage, size: .zero)
    }

    @concurrent
    static func prepared(from data: Data) async -> DecodedImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return make(cgImage: image)
    }

    var encodableCGImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    var encodedOrientation: CGImagePropertyOrientation { .up }

    var orientedPixelSize: CodexImagePixelSize {
        if let cg = encodableCGImage {
            return CodexImagePixelSize(width: cg.width, height: cg.height)
        }
        return CodexImagePixelSize(width: max(1, Int(size.width.rounded(.towardZero))), height: max(1, Int(size.height.rounded(.towardZero))))
    }

    func scaledOpaque(toPixelWidth width: Int, height: Int) -> DecodedImage? {
        guard let source = encodableCGImage,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage().map { Self.make(cgImage: $0) }
    }
}

extension Image {
    init(decoded: DecodedImage) {
        self.init(nsImage: decoded)
    }
}
#endif
