import SwiftUI

struct ComposerMediaTile: View {
    enum Content {
        case legacyImage(CodexImageAttachment)
        case file(ComposerFileAttachment)

        init?(_ source: ComposerAttachment.Content) {
            switch source {
            case .legacyImage(let image): self = .legacyImage(image)
            case .file(let file): self = .file(file)
            case .text: return nil
            }
        }
    }

    let attachment: Content
    let stagedCopy: URL?
    let uploadState: FileAttachmentImports.UploadState?
    let removeAction: () -> Void
    let retryAction: () -> Void
    @InterfaceScaledMetric(relativeTo: .caption) private var height: CGFloat = ComposerMetrics.attachmentTileHeight

    var body: some View {
        ComposerTile(height: height, removeLabel: "Remove attachment", removeAction: removeAction) { content }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction(named: "Remove", removeAction)
            .accessibilityActions {
                if uploadFailed {
                    Button("Retry upload", action: retryAction)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch attachment {
        case .legacyImage(let image):
            AttachmentThumbnail(attachment: MessageAttachment(id: image.id, content: .imageData(image)), dimension: height)
                .equatable()
                .frame(width: height, height: height)
                .overlay { imageStatus }
        case .file(let file) where HostImagePreviews.canPreview(name: file.name):
            ComposerImageFileThumbnail(file: file, stagedCopy: stagedCopy, dimension: height)
                .frame(width: height, height: height)
                .overlay { if file.uploaded == nil { imageStatus } }
        case .file(let file):
            AttachmentTileSummary(symbol: "doc", title: file.name, maximumWidth: height * 2.6, truncation: .middle) {
                fileStatus(file)
            }
            .frame(width: height * 2.6)
        }
    }

    @ViewBuilder
    private func fileStatus(_ file: ComposerFileAttachment) -> some View {
        switch (file.placement, uploadState) {
        case (.uploaded, _):
            Text("\(fileSize(file)) · Uploaded")
                .foregroundStyle(.secondary)
        case (.staged, .failed(let message)):
            HStack(spacing: 4) {
                Text(message)
                    .foregroundStyle(.red)
                Button("Retry", systemImage: "arrow.clockwise", action: retryAction)
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(.rect)
                    .buttonStyle(ResponsiveButtonStyle())
                    .tooltip("Retry upload")
            }
        case (.staged, .uploading(let fraction)):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        case (.staged, .waiting(let fraction)):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.secondary)
        case (.staged, nil):
            Text("\(fileSize(file)) · Waiting")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var imageStatus: some View {
        switch uploadState {
        case .failed:
            Button(action: retryAction) {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .scaledFrame(width: ComposerMetrics.removeBadgeDiameter, height: ComposerMetrics.removeBadgeDiameter)
                    .background(.red, in: .circle)
                    .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(ResponsiveButtonStyle())
            .tooltip("Retry upload")
        case .uploading(let fraction):
            uploadProgress(fraction)
        case .waiting(let fraction):
            uploadProgress(fraction)
                .opacity(0.5)
        case nil:
            uploadProgress(0)
        }
    }

    private func uploadProgress(_ fraction: Double) -> some View {
        ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(.white)
            .padding(6)
            .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var uploadFailed: Bool {
        guard case .failed = uploadState else { return false }
        if case .file(let file) = attachment { return file.uploaded == nil }
        return true
    }

    private func fileSize(_ file: ComposerFileAttachment) -> String {
        ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
    }

    private var accessibilityLabel: String {
        switch attachment {
        case .legacyImage(let image):
            let size = ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file)
            return "Image, \(image.format.displayName), \(image.pixelSize.width) by \(image.pixelSize.height), \(size), \(pendingStatus)"
        case .file(let file):
            return "File, \(file.name), \(fileSize(file)), \(file.uploaded == nil ? pendingStatus : "uploaded")"
        }
    }

    private var pendingStatus: String {
        switch uploadState {
        case .failed(let message): "upload failed, \(message)"
        case .uploading(let fraction): "uploading, \(Int(fraction * 100)) percent"
        case .waiting(let fraction): "upload paused at \(Int(fraction * 100)) percent, continues automatically"
        case nil: "waiting to upload"
        }
    }
}
