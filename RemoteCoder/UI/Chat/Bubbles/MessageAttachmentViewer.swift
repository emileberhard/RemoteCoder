import SwiftUI

struct MessageAttachmentViewer: View {
    let attachment: MessageAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: DecodedImage?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(attachment.preview.isEmpty ? "Attachment" : title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if case .text(let text) = attachment.content {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Copy", systemImage: "doc.on.doc") { HapticService.shared.copy(text) }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { dismiss() }
                    }
                }
        }
        .attachmentViewerSize()
        .task(id: attachment) {
            image = nil
            finished = false
            do {
                let prepared: DecodedImage?
                switch attachment.content {
                case .imageData(let data):
                    prepared = try await ImagePreparation.shared.thumbnail(data: data.data, maxDimension: max(data.pixelSize.width, data.pixelSize.height))
                case .image(let reference):
                    prepared = try await ImagePreparation.shared.thumbnail(reference: reference, maxDimension: 4096)
                case .text, .file, .fileReference, .localImage, .canonicalImage, .unavailableImage: prepared = nil
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

    private var title: String {
        if case .text = attachment.content { "Pasted Text" } else { "Image" }
    }

    @ViewBuilder private var content: some View {
        switch attachment.content {
        case .text(let text):
            ScrollView {
                Text(verbatim: text)
                    .scaledFont(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .accessibilityIdentifier("pasted-text-viewer")
        case .imageData, .image, .canonicalImage, .unavailableImage, .localImage:
            if let image {
                Image(decoded: image).resizable().scaledToFit().padding()
                    .accessibilityLabel("Attached image")
            } else if finished {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            } else {
                ProgressView()
            }
        case .file, .fileReference:
            EmptyView()
        }
    }
}
