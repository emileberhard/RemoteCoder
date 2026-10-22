import CoreGraphics
import Foundation
import ImageIO
import Photos

actor CameraPhotoProcessing {
    static let trayPixels = 160
    static let reviewPixels = 512

    func thumbnail(_ file: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    func save(_ file: URL) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Photos access is off in Settings. This photo was not saved to the camera roll."
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
            return nil
        } catch { return "Photo not saved to the camera roll: \(error.localizedDescription)" }
    }
}
