import SwiftUI

struct HostFileStatusBar: View {
    let opener: HostFileOpener
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShown: Bool { opener.showsProgress || opener.lastDocument != nil }

    var body: some View {
        ZStack {
            if isShown {
                HStack(spacing: 0) { content }
                    .scaledFrame(maxWidth: ReadableContentWidth.composer)
                    .appGlass(.standard, in: .capsule, interactive: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isShown)
    }

    @ViewBuilder
    private var content: some View {
        if opener.showsProgress {
            HStack(spacing: 10) {
                downloadProgress
                VStack(alignment: .leading, spacing: 1) {
                    Text(opener.loadingName ?? "Downloading file")
                        .scaledFont(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress = opener.progress {
                        Text(Self.transferred(progress))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, 16)
            .accessibilityElement(children: .combine)
            closeButton("Cancel Download", action: opener.cancelDownload)
        } else if let file = opener.lastDocument {
            let name = file.name
            Button(action: opener.showOptions) {
                HStack(spacing: 8) {
                    Image(systemName: LinkChip.symbol(forFileNamed: name))
                        .foregroundStyle(.secondary)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.tint)
                }
                .scaledFont(.subheadline)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget)
                .contentShape(.rect)
            }
            .appButtonFeedback()
            .accessibilityLabel(name)
            .accessibilityHint("Save or share the file")
            closeButton("Dismiss", action: opener.invalidate)
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        if let progress = opener.progress, let total = progress.totalBytes, total > 0 {
            ProgressView(value: Double(progress.bytesReceived), total: Double(total))
                .progressViewStyle(.circular)
                .controlSize(.small)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func closeButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                .contentShape(.circle)
        }
        .appIconButtonFeedback()
        .accessibilityLabel(title)
        .tooltip(title)
    }

    private static func transferred(_ progress: HostFileProgress) -> String {
        let received = progress.bytesReceived.formatted(.byteCount(style: .file))
        guard let total = progress.totalBytes, total > 0 else { return received }
        return "\(received) of \(total.formatted(.byteCount(style: .file)))"
    }
}
