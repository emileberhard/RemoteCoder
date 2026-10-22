import SwiftUI

struct ComposerImageFileThumbnail: View {
    let file: ComposerFileAttachment
    let stagedCopy: URL?
    let dimension: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.chatImageSource) private var source
    @State private var image: DecodedImage?
    @State private var failed = false

    private struct Request: Equatable { let id: UUID; let isUploaded: Bool }

    var body: some View {
        ThumbnailSurface(image: image, failed: failed)
            .task(id: Request(id: file.id, isUploaded: file.uploaded != nil)) {
                guard image == nil else { return }
                let pixels = Int((dimension * displayScale).rounded(.up))
                if let stagedCopy, let local = try? await ImagePreparation.shared.thumbnail(url: stagedCopy, maxDimension: pixels) {
                    image = local
                } else if let uploaded = file.uploaded, let source,
                          let reference = source.reference(for: URL(fileURLWithPath: uploaded.path)) {
                    image = try? await source.previews.thumbnail(reference, maxDimension: pixels)
                    failed = image == nil && !Task.isCancelled
                }
            }
    }
}
