import Foundation
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
struct ImagePreparationTests {
    @Test func thumbnailsAreBoundedAndMalformedImagesHaveNoFullResolutionFallback() async throws {
        let data = try #require(image(width: 1_200, height: 800).pngData())
        let thumbnail = try #require(try await ImagePreparation.shared.thumbnail(data: data, maxDimension: 120))
        #expect(thumbnail.cgImage?.width == 120)
        #expect(thumbnail.cgImage?.height == 80)
        #expect(try await ImagePreparation.shared.thumbnail(data: Data([0, 1, 2]), maxDimension: 120) == nil)
        #expect(try await ImagePreparation.shared.thumbnail(data: data, maxDimension: 0) == nil)
    }

    @Test func aCancelledDecodeDoesNotPerformWorkOrReturnAnImage() async {
        let task = Task { try await ImagePreparation.shared.thumbnail(data: Data([1]), maxDimension: 120) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
    }
}
