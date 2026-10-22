import SwiftUI

struct MessageAttachmentChip: View {
    let attachment: MessageAttachment
    let open: () -> Void
    @Environment(\.openURL) private var openURL
    @InterfaceScaledMetric(relativeTo: .caption) private var height = ComposerMetrics.attachmentTileHeight

    var body: some View {
        Button {
            HapticService.shared.play(.selection)
            if let path { openURL(URL(fileURLWithPath: path)) } else { open() }
        } label: {
            Group {
                if showsThumbnail {
                    AttachmentThumbnail(attachment: attachment, dimension: height)
                        .equatable()
                        .frame(width: height, height: height)
                } else {
                    AttachmentTileSummary(symbol: path == nil ? "text.alignleft" : "doc", title: attachment.preview,
                                          maximumWidth: height * 6.5, truncation: path == nil ? .tail : .middle) {
                        if !attachment.detail.isEmpty { Text(attachment.detail).foregroundStyle(.secondary) }
                    }
                    .frame(minWidth: height * 2.6, maxWidth: height * 6.5)
                }
            }
            .frame(height: height)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(path == nil ? attachment.preview : "File \(attachment.preview)")
        .accessibilityValue(attachment.detail)
        .accessibilityIdentifier("sent-attachment-\(attachment.id)")
        .contextMenu {
            if case .file(let file) = attachment.content {
                FileAttachmentMenu(file: file)
            } else if let path {
                if HostFilePreviewPolicy.permitsQuickLook(attachment.preview), !HostFilePreviewPolicy.isMarkdown(attachment.preview) {
                    Button("Quick Look") { openURL(URL(fileURLWithPath: path)) }
                }
                Button("Copy Path") { HapticService.shared.copy(path) }
            }
        }
    }

    private var showsThumbnail: Bool {
        switch attachment.content {
        case .imageData, .image, .canonicalImage, .unavailableImage, .localImage: true
        case .file(let file): HostImagePreviews.canPreview(name: file.path)
        case .fileReference(let path): HostImagePreviews.canPreview(name: path)
        case .text: false
        }
    }

    private var path: String? {
        switch attachment.content {
        case .file(let file): file.path
        case .fileReference(let path), .localImage(let path): path
        case .text, .imageData, .image, .canonicalImage, .unavailableImage: nil
        }
    }
}
