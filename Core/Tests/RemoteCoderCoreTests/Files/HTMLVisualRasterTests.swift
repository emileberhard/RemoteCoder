import CoreGraphics
import Foundation
import Testing
@testable import RemoteCoderCore

struct HTMLVisualRasterTests {
    @Test func rasterCoversATallPageTopToBottom() async throws {
        let budget = HTMLVisualRasterBudget(capacity: HTMLVisualRasterBudget.maximumPixels, imagePixels: HTMLVisualRasterBudget.maximumImagePixels)
        let raster = try #require(await budget.rasterize(try Self.pdf(width: 200, height: 6_000), displayScale: 2, minimumScale: 1))
        #expect(raster.image.width == 400)
        #expect(raster.image.height == 12_000)
        #expect(raster.displayHeight == 6_000)
        #expect(budget.reservedPixels == 400 * 12_000)
        #expect(try Self.pixel(raster.image, row: 0) == Self.red)
        #expect(try Self.pixel(raster.image, row: 12_000 - 1) == Self.blue)
    }

    @Test func degradedRasterKeepsThePageHeight() async throws {
        let budget = HTMLVisualRasterBudget(capacity: 200 * 6_000, imagePixels: HTMLVisualRasterBudget.maximumImagePixels)
        let raster = try #require(await budget.rasterize(try Self.pdf(width: 200, height: 6_000), displayScale: 2, minimumScale: 1))
        #expect(raster.image.height == 6_000)
        #expect(raster.displayHeight == 6_000)
    }

    @Test func budgetBoundsResidentAndInFlightPixelsUntilReservationsEnd() throws {
        let budget = HTMLVisualRasterBudget(capacity: 1_000, imagePixels: 1_000)
        var first = budget.reserve(width: 10, height: 10, displayScale: 2, minimumScale: 1)
        let second = try #require(budget.reserve(width: 10, height: 10, displayScale: 2, minimumScale: 1))
        let degraded = try #require(budget.reserve(width: 10, height: 10, displayScale: 2, minimumScale: 1))
        #expect(first?.width == 20)
        #expect(second.width == 20)
        #expect(degraded.width == 14 && degraded.height == 14)
        #expect(budget.reservedPixels == 996)
        #expect(budget.reserve(width: 10, height: 10, displayScale: 2, minimumScale: 1) == nil)
        first = nil
        #expect(budget.reservedPixels == 596)
        do {
            let again = budget.reserve(width: 10, height: 10, displayScale: 2, minimumScale: 1)
            #expect(again?.width == 20)
            #expect(budget.reservedPixels == 996)
        }
        #expect(budget.reservedPixels == 596)
    }

    @Test func eachRasterStaysWithinThePerImageAndTextureLimits() throws {
        let budget = HTMLVisualRasterBudget(capacity: HTMLVisualRasterBudget.maximumPixels, imagePixels: HTMLVisualRasterBudget.maximumImagePixels)
        let wide = try #require(budget.reserve(width: 1_162, height: 6_000, displayScale: 2, minimumScale: 1))
        #expect(wide.width * wide.height <= HTMLVisualRasterBudget.maximumImagePixels)
        #expect(wide.width > 1_162 && wide.height > 6_000)
        let narrow = try #require(budget.reserve(width: 100, height: 12_000, displayScale: 3, minimumScale: 1))
        #expect(narrow.height <= HTMLVisualRasterBudget.maximumDimension)
    }

    @Test func aSharperBudgetGrantsOnlyAboveTheBaseScale() async throws {
        let pdf = try Self.pdf(width: 390, height: 6_000)
        let base = try #require(await HTMLVisualRasterBudget(capacity: HTMLVisualRasterBudget.maximumPixels,
            imagePixels: HTMLVisualRasterBudget.maximumImagePixels).rasterize(pdf, displayScale: 3, minimumScale: 1))
        #expect(base.reservation.scale < 2)
        let sharp = HTMLVisualRasterBudget(capacity: 16 << 20, imagePixels: 16 << 20)
        let upgrade = try #require(await sharp.rasterize(pdf, displayScale: 3, minimumScale: base.reservation.scale.nextUp))
        #expect(upgrade.reservation.scale > 2.6 && upgrade.reservation.scale < 3)
        #expect(upgrade.image.height > base.image.height && upgrade.displayHeight == 6_000)
        #expect(sharp.reserve(width: 390, height: 6_000, displayScale: 3, minimumScale: base.reservation.scale.nextUp) == nil)
        #expect(sharp.reservedPixels == upgrade.image.width * upgrade.image.height)
    }

    private static let red = [UInt8](arrayLiteral: 255, 0, 0, 255)
    private static let blue = [UInt8](arrayLiteral: 0, 0, 255, 255)

    private static func pdf(width: Double, height: Double) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func pixel(_ image: CGImage, row: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height - 1 - row),
                width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }
}
