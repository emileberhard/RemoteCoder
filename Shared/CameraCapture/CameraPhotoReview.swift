import CoreGraphics
import Foundation
import SwiftUI

struct CameraPhotoReview: View {
    let file: URL
    let processing: CameraPhotoProcessing
    @State private var image: CGImage?
    @State private var width: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Color.black.overlay { ProgressView() } }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(3.0 / 4, contentMode: .fit)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: width) {
            guard width > 0 else { return }
            let pixels = min(Int((width * 4 / 3 * displayScale).rounded(.up)), CameraPhotoProcessing.reviewPixels)
            let image = await processing.thumbnail(file, pixels: pixels)
            if !Task.isCancelled { self.image = image }
        }
        .onDisappear { image = nil }
    }
}
