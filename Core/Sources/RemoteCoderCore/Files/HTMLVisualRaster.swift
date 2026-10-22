import CoreGraphics
import Foundation
import Synchronization

struct HTMLVisualRaster: Sendable {
    let image: CGImage
    let displayHeight: Double
    let reservation: HTMLVisualRasterBudget.Reservation
}

final class HTMLVisualRasterBudget: Sendable {
    static let maximumPixels = 32 << 20
    static let maximumImagePixels = maximumPixels / 4
    static let maximumDimension = 16_384

    final class Reservation: Sendable {
        let width: Int
        let height: Int
        let scale: Double
        private let budget: HTMLVisualRasterBudget

        fileprivate init(width: Int, height: Int, scale: Double, budget: HTMLVisualRasterBudget) {
            self.width = width
            self.height = height
            self.scale = scale
            self.budget = budget
        }

        deinit { budget.release(width * height) }
    }

    private let capacity: Int
    private let imagePixels: Int
    private let reserved = Mutex(0)

    init(capacity: Int, imagePixels: Int) {
        self.capacity = capacity
        self.imagePixels = imagePixels
    }

    var reservedPixels: Int { reserved.withLock { $0 } }
    var availablePixels: Int { capacity - reservedPixels }

    func reserve(width: Double, height: Double, displayScale: Double, minimumScale: Double) -> Reservation? {
        guard width.isFinite, height.isFinite, width > 0, height > 0, displayScale > 0 else { return nil }
        return reserved.withLock { reserved in
            let available = Double(min(imagePixels, capacity - reserved))
            let scale = min(displayScale, (available / (width * height)).squareRoot(),
                Double(Self.maximumDimension) / max(width, height))
            guard scale >= minimumScale else { return nil }
            let pixelWidth = Int((width * scale).rounded(.down))
            let pixelHeight = Int((height * scale).rounded(.down))
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }
            reserved += pixelWidth * pixelHeight
            return Reservation(width: pixelWidth, height: pixelHeight, scale: scale, budget: self)
        }
    }

    @concurrent
    func rasterize(_ pdf: Data, displayScale: Double, minimumScale: Double) async -> HTMLVisualRaster? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard !Task.isCancelled, let reservation = reserve(width: box.width, height: box.height, displayScale: displayScale,
                  minimumScale: minimumScale),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: reservation.width, height: reservation.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: CGFloat(reservation.width) / box.width, y: CGFloat(reservation.height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard !Task.isCancelled, let image = context.makeImage() else { return nil }
        return HTMLVisualRaster(image: image, displayHeight: box.height, reservation: reservation)
    }

    private func release(_ pixels: Int) {
        reserved.withLock { $0 -= pixels }
    }
}
