import SwiftUI

struct AttachmentThumbnail: View, Equatable {
    let attachment: MessageAttachment
    let dimension: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.chatImageSource) private var source
    @State private var image: DecodedImage?
    @State private var finished = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attachment == rhs.attachment && lhs.dimension == rhs.dimension
    }

    private struct Request: Equatable { let attachment: MessageAttachment; let pixels: Int }

    var body: some View {
        let request = Request(attachment: attachment, pixels: Int((dimension * displayScale).rounded(.up)))
        ThumbnailSurface(image: image, failed: finished)
            .accessibilityLabel(attachment.preview)
            .task(id: request) {
                image = nil
                finished = false
                let pixels = request.pixels
                do {
                    let prepared: DecodedImage?
                    switch attachment.content {
                    case .imageData(let data):
                        prepared = try await ImagePreparation.shared.thumbnail(data: data.data, maxDimension: pixels)
                    case .image(let reference):
                        prepared = try await ImagePreparation.shared.thumbnail(reference: reference, maxDimension: pixels)
                    case .localImage(let path), .fileReference(let path):
                        prepared = try await hostThumbnail(path, maxDimension: pixels)
                    case .file(let file):
                        prepared = try await hostThumbnail(file.path, maxDimension: pixels)
                    case .text, .canonicalImage, .unavailableImage: prepared = nil
                    }
                    try Task.checkCancellation()
                    image = prepared
                    finished = true
                } catch {
                    guard !Task.isCancelled else { return }
                    finished = true
                }
            }
    }

    private func hostThumbnail(_ path: String, maxDimension: Int) async throws -> DecodedImage? {
        guard let source, let reference = source.reference(for: URL(fileURLWithPath: path)) else { return nil }
        return try await source.previews.thumbnail(reference, maxDimension: maxDimension)
    }
}

struct ThumbnailSurface: View {
    let image: DecodedImage?
    let failed: Bool

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(decoded: image).resizable().scaledToFill()
                } else {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                        .scaledFont(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
    }
}
