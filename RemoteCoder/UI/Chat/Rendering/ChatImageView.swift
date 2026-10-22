import SwiftUI

struct ChatImageSource: Equatable {
    private weak var screen: ChatScreenModel?
    private let identity: ObjectIdentifier
    let previews: HostImagePreviews

    @MainActor init(screen: ChatScreenModel) {
        self.screen = screen
        identity = ObjectIdentifier(screen)
        previews = screen.imagePreviews
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
    }

    @MainActor func reference(for url: URL) -> HostFileReference? {
        screen?.imagePreviewReference(for: url)
    }

    @MainActor var fileOpener: HostFileOpener? { screen?.target.fileOpener }

    @MainActor func open(_ url: URL, transition: HostFileTransition?, presentationScope: UUID?) {
        _ = screen?.openFileURL(url, transition: transition, presentationScope: presentationScope)
    }

    @MainActor func open(_ file: EmbeddedFileRequest, frame: HostFileTransition.Frame?, presentationScope: UUID?) {
        screen?.openEmbeddedFile(file, frame: frame, presentationScope: presentationScope)
    }
}

struct ChatImageView: View {
    private static let maximumHeight: CGFloat = 480
    private static let cornerRadius: CGFloat = 12

    let url: URL
    let alt: String
    @Environment(\.chatImageSource) private var source
    @Environment(\.openURL) private var openURL
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.transcriptRowVisibility) private var rowVisibility
    @State private var loaded: (reference: HostFileReference, preview: HostImagePreview)?
    @State private var failure: (reference: HostFileReference, message: String)?

    var body: some View {
        if let source, let reference = source.reference(for: url) {
            preview(reference, source: source)
        } else {
            Button { openURL(url) } label: {
                Label(alt, systemImage: "photo")
                    .foregroundStyle(.tint)
            }
            .appButtonFeedback()
            .accessibilityHint("Opens the image")
        }
    }

    private func preview(_ reference: HostFileReference, source: ChatImageSource) -> some View {
        let shown = loaded?.reference == reference ? loaded?.preview : source.previews.cached(reference)
        let failed = failure?.reference == reference ? failure?.message : nil
        let active = shown == nil && failed == nil && rowVisibility?.isVisible == true && visualsVisible && scenePhase == .active
        let request = active ? reference : nil
        return Group {
            if let shown {
                picture(shown, source: source)
            } else if let failed {
                Button { source.open(url, transition: nil, presentationScope: nil) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(alt, systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.tint)
                        Text(failed)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .appButtonFeedback()
            } else {
                Button { source.open(url, transition: nil, presentationScope: nil) } label: {
                    placeholder(pixelSize: source.previews.pixelSize(for: reference), active: active)
                }
                .appButtonFeedback()
            }
        }
        .accessibilityLabel(alt)
        .accessibilityAddTraits(.isImage)
        .accessibilityHint("Opens the image")
        .accessibilityIdentifier("chat-image")
        .onChange(of: shown.map { ObjectIdentifier($0.image) }, initial: true) {
            if loaded?.reference != reference, let shown {
                loaded = (reference, shown)
            }
        }
        .task(id: request) {
            guard let request else { return }
            await load(request, previews: source.previews)
        }
    }

    private func picture(_ preview: HostImagePreview, source: ChatImageSource) -> some View {
        let naturalWidth = preview.pixelSize.width / 2
        let aspect = preview.pixelSize.width / max(1, preview.pixelSize.height)
        return GeometryReader { geometry in
            Button {
                let frame = geometry.frame(in: .global)
                source.open(url, transition: HostFileTransition(frame: { frame }, image: preview.image), presentationScope: nil)
            } label: {
                Image(decoded: preview.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
            .appButtonFeedback()
            .accessibilityLabel(alt)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: min(naturalWidth, Self.maximumHeight * aspect))
    }

    @ViewBuilder private func placeholder(pixelSize: CGSize?, active: Bool) -> some View {
        if let pixelSize {
            let aspect = pixelSize.width / max(1, pixelSize.height)
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.quaternary)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: min(pixelSize.width / 2, Self.maximumHeight * aspect))
                .overlay { if active { ProgressView() } }
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .overlay { if active { ProgressView() } }
        }
    }

    private func load(_ reference: HostFileReference, previews: HostImagePreviews) async {
        do {
            let preview = try await previews.preview(reference)
            try Task.checkCancellation()
            loaded = (reference, preview)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = (reference, error.localizedDescription)
        }
    }
}
